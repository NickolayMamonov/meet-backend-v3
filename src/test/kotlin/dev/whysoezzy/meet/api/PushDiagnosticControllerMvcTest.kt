package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.controller.AdminPushController
import dev.whysoezzy.meet.api.error.*
import dev.whysoezzy.meet.config.AdminProperties
import dev.whysoezzy.meet.config.PushWebConfiguration
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.*
import dev.whysoezzy.meet.service.push.*
import org.hamcrest.Matchers.hasSize
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest
import org.springframework.context.annotation.Import
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.test.context.TestPropertySource
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.*
import java.util.Optional
import java.util.UUID

private const val ADMIN_KEY = "test-admin-key"
private const val INSTALLATION_ID = "123e4567-e89b-12d3-a456-426614174000"

@WebMvcTest(controllers = [AdminPushController::class])
@TestPropertySource(properties = ["app.push.provider-enabled=true", "app.push.diagnostic-enabled=true"])
@Import(
    ApiExceptionHandler::class, ApiErrorResponseWriter::class, PushWebConfiguration::class,
    StorageProperties::class, ApiAuthenticationEntryPoint::class, ApiAccessDeniedHandler::class,
    AdminKeyAuthFilter::class, JwtAuthFilter::class, SecurityConfig::class,
)
class PushDiagnosticControllerMvcTest @Autowired constructor(private val mockMvc: MockMvc) {
    @MockitoBean private lateinit var service: PushDiagnosticService
    @MockitoBean private lateinit var jwtService: JwtService
    @MockitoBean private lateinit var userRepository: UserRepository
    @MockitoBean private lateinit var adminProperties: AdminProperties

    @BeforeEach
    fun adminKey() {
        Mockito.`when`(adminProperties.apiKey).thenReturn(ADMIN_KEY)
    }

    @Test
    fun `admin key derives ROLE_ADMIN and exact command and safe response shapes`() {
        Mockito.`when`(service.send(command())).thenReturn(PushDiagnosticResponse.Single(DiagnosticCallResult.Accepted))
        mockMvc.perform(request(body(), ADMIN_KEY)).andExpect(status().isOk)
            .andExpect(jsonPath("$.*", hasSize<Any>(1))).andExpect(jsonPath("$.result").value("ACCEPTED"))
            .andExpect(jsonPath("$.installationId").doesNotExist())

        val pair = command(offset = 1440, mode = PushDiagnosticMode.DEDUP_PAIR)
        Mockito.`when`(service.send(pair)).thenReturn(
            PushDiagnosticResponse.Pair(
                DiagnosticAggregateResult.ACCEPTED_PAIR,
                DiagnosticCallResult.Accepted,
                DiagnosticCallResult.Accepted,
            ),
        )
        mockMvc.perform(request(body(offset = 1440, mode = "DEDUP_PAIR"), ADMIN_KEY)).andExpect(status().isOk)
            .andExpect(jsonPath("$.*", hasSize<Any>(3)))
            .andExpect(jsonPath("$.result").value("ACCEPTED_PAIR"))
            .andExpect(jsonPath("$.first").value("ACCEPTED"))
            .andExpect(jsonPath("$.second").value("ACCEPTED"))
        Mockito.verify(service).send(command())
        Mockito.verify(service).send(pair)
    }

    @Test
    fun `every safe call category and inconclusive pair serialize exactly`() {
        listOf(
            DiagnosticCallResult.Accepted to "ACCEPTED",
            DiagnosticCallResult.InvalidTarget to "INVALID_TARGET",
            DiagnosticCallResult.RetryableFailure to "RETRYABLE_FAILURE",
            DiagnosticCallResult.ProviderUnavailable to "PROVIDER_UNAVAILABLE",
            DiagnosticCallResult.NotAttempted to "NOT_ATTEMPTED",
        ).forEach { (result, expected) ->
            Mockito.`when`(service.send(command())).thenReturn(PushDiagnosticResponse.Single(result))
            mockMvc.perform(request(body(), ADMIN_KEY)).andExpect(status().isOk)
                .andExpect(jsonPath("$.result").value(expected))
        }
        Mockito.`when`(service.send(command(mode = PushDiagnosticMode.DEDUP_PAIR))).thenReturn(
            PushDiagnosticResponse.Pair(
                DiagnosticAggregateResult.INCONCLUSIVE,
                DiagnosticCallResult.RetryableFailure,
                DiagnosticCallResult.NotAttempted,
            ),
        )
        mockMvc.perform(request(body(mode = "DEDUP_PAIR"), ADMIN_KEY)).andExpect(status().isOk)
            .andExpect(jsonPath("$.result").value("INCONCLUSIVE"))
            .andExpect(jsonPath("$.first").value("RETRYABLE_FAILURE"))
            .andExpect(jsonPath("$.second").value("NOT_ATTEMPTED"))
    }

    @Test
    fun `real admin filter rejects missing blank wrong and unconfigured keys`() {
        listOf(null, "", "wrong").forEach {
            mockMvc.perform(request(body(), it)).andExpect(status().isForbidden)
                .andExpect(jsonPath("$.code").value("FORBIDDEN"))
        }
        listOf("", "   ").forEach {
            Mockito.`when`(adminProperties.apiKey).thenReturn(it)
            mockMvc.perform(request(body(), ADMIN_KEY)).andExpect(status().isForbidden)
        }
        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `JWT and preauthenticated ROLE_ADMIN cannot bypass missing admin key`() {
        Mockito.`when`(jwtService.validateToken("user-token")).thenReturn(true)
        Mockito.`when`(jwtService.getUserIdFromToken("user-token")).thenReturn(7)
        Mockito.`when`(jwtService.getAuthVersionFromToken("user-token")).thenReturn(2)
        Mockito.`when`(userRepository.findById(7)).thenReturn(
            Optional.of(User("Test", "User", "+79990000000").also { it.id = 7; it.authVersion = 2 }),
        )
        mockMvc.perform(request(body(), null).header("Authorization", "Bearer user-token"))
            .andExpect(status().isForbidden)
        mockMvc.perform(
            request(body(), null).with(
                org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors
                    .user("admin").roles("ADMIN"),
            ),
        ).andExpect(status().isForbidden)
        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `unknown not-owned and inactive selections are distinct but indistinguishable`() {
        val selections = listOf(
            command(installationId = "223e4567-e89b-12d3-a456-426614174000"),
            command(userId = 8, installationId = "323e4567-e89b-12d3-a456-426614174000"),
            command(meetingId = 43, installationId = "423e4567-e89b-12d3-a456-426614174000"),
        )
        selections.forEach {
            Mockito.`when`(service.send(it)).thenThrow(NotFoundException("Push diagnostic target not found"))
            mockMvc.perform(request(body(it.userId, it.installationId.toString(), it.meetingId), ADMIN_KEY))
                .andExpect(status().isNotFound).andExpect(jsonPath("$.code").value("NOT_FOUND"))
                .andExpect(jsonPath("$.message").value("Push diagnostic target not found"))
                .andExpect(jsonPath("$.installationId").doesNotExist())
            Mockito.verify(service).send(it)
        }
    }

    @Test
    fun `strict JSON rejects unknown duplicate coercion trailing malformed and oversize bodies`() {
        val valid = body()
        val missingOrNull = listOf(
            valid.replace("\"userId\":7,", ""),
            valid.replace("\"userId\":7", "\"userId\":null"),
            valid.replace("\"installationId\":\"$INSTALLATION_ID\",", ""),
            valid.replace("\"installationId\":\"$INSTALLATION_ID\"", "\"installationId\":null"),
            valid.replace("\"meetingId\":42", ""),
            valid.replace("\"meetingId\":42", "\"meetingId\":null"),
            valid.replace("\"reminderOffsetMinutes\":60,", ""),
            valid.replace("\"reminderOffsetMinutes\":60", "\"reminderOffsetMinutes\":null"),
            valid.replace(",\"mode\":\"SINGLE\"", ""),
            valid.replace("\"mode\":\"SINGLE\"", "\"mode\":null"),
        )
        listOf(
            *missingOrNull.toTypedArray(),
            valid.dropLast(1) + ""","topic":"all"}""",
            valid.replace("\"userId\":7", "\"userId\":7,\"userId\":8"),
            valid.replace("\"installationId\":\"$INSTALLATION_ID\",", ""),
            valid.replace("\"meetingId\":42", "\"meetingId\":null"),
            valid.replace("\"userId\":7", "\"userId\":\"7\""),
            valid.replace("\"meetingId\":42", "\"meetingId\":42.0"),
            valid.replace("\"reminderOffsetMinutes\":60", "\"reminderOffsetMinutes\":\"60\""),
            valid.replace("\"mode\":\"SINGLE\"", "\"mode\":1"),
            """[$valid]""", """"diagnostic"""", "$valid {}", valid.dropLast(1),
        ).forEach {
            mockMvc.perform(request(it, ADMIN_KEY)).andExpect(status().isBadRequest)
                .andExpect(jsonPath("$.code").value("BAD_REQUEST"))
        }
        mockMvc.perform(request(valid.dropLast(1) + ""","padding":"${"x".repeat(16 * 1024)}"}""", ADMIN_KEY))
            .andExpect(status().`is`(HttpStatus.PAYLOAD_TOO_LARGE.value()))
            .andExpect(jsonPath("$.code").value("PAYLOAD_TOO_LARGE"))
        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `closed target values query parameters media type and route are enforced`() {
        listOf(
            body(userId = 0), body(userId = -1), body(meetingId = 0), body(meetingId = -1),
            body(installationId = INSTALLATION_ID.uppercase()), body(installationId = "not-a-uuid"),
            body(installationId = "123e4567-e89b-12d3-a456-42661417400"),
            body(offset = 59), body(offset = 1441), body(mode = "single"), body(mode = "BROADCAST"),
        ).forEach { mockMvc.perform(request(it, ADMIN_KEY)).andExpect(status().isBadRequest) }
        listOf("?topic=all", "?token=secret", "?userId=8", "?mode=SINGLE&mode=DEDUP_PAIR", "?empty=").forEach {
            mockMvc.perform(request(body(), ADMIN_KEY, it)).andExpect(status().isBadRequest)
        }
        mockMvc.perform(
            post("/admin/push/diagnostic").header("X-Admin-Key", ADMIN_KEY)
                .contentType("application/vnd.example+json").content(body()),
        ).andExpect(status().isUnsupportedMediaType)
        mockMvc.perform(
            post("/admin/push/diagnostic/unknown").header("X-Admin-Key", ADMIN_KEY)
                .contentType(MediaType.APPLICATION_JSON).content(body()),
        ).andExpect(status().isNotFound)
        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `encoded noncanonical UUID is rejected before service interaction`() {
        mockMvc.perform(
            request(
                body(installationId = "123e4567-e89b-12d3-a456-426614174%30%30%30"),
                ADMIN_KEY,
            ),
        ).andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.code").value("BAD_REQUEST"))

        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `admission failure is sanitized PUSH_UNAVAILABLE`() {
        Mockito.`when`(service.send(command())).thenThrow(PushUnavailableException())
        mockMvc.perform(request(body(), ADMIN_KEY)).andExpect(status().isServiceUnavailable)
            .andExpect(jsonPath("$.*", hasSize<Any>(5)))
            .andExpect(jsonPath("$.code").value("PUSH_UNAVAILABLE"))
            .andExpect(jsonPath("$.message").value("Push service is temporarily unavailable"))
            .andExpect(jsonPath("$.installationId").doesNotExist())
    }

    private fun request(body: String, key: String?, query: String = "") =
        post("/admin/push/diagnostic$query").apply { key?.let { header("X-Admin-Key", it) } }
            .contentType(MediaType.APPLICATION_JSON).content(body)
    private fun body(
        userId: Long = 7,
        installationId: String = INSTALLATION_ID,
        meetingId: Long = 42,
        offset: Int = 60,
        mode: String = "SINGLE",
    ) = """{"userId":$userId,"installationId":"$installationId","meetingId":$meetingId,"reminderOffsetMinutes":$offset,"mode":"$mode"}"""
    private fun command(
        userId: Long = 7,
        installationId: String = INSTALLATION_ID,
        meetingId: Long = 42,
        offset: Int = 60,
        mode: PushDiagnosticMode = PushDiagnosticMode.SINGLE,
    ) = PushDiagnosticCommand(userId, UUID.fromString(installationId), meetingId, offset, mode)
}

@WebMvcTest(controllers = [AdminPushController::class])
@TestPropertySource(properties = ["app.push.provider-enabled=false", "app.push.diagnostic-enabled=false"])
@Import(
    ApiExceptionHandler::class, ApiErrorResponseWriter::class, PushWebConfiguration::class,
    StorageProperties::class, ApiAuthenticationEntryPoint::class, ApiAccessDeniedHandler::class,
    AdminKeyAuthFilter::class, JwtAuthFilter::class, SecurityConfig::class,
)
class PushDiagnosticControllerDisabledMvcTest @Autowired constructor(private val mockMvc: MockMvc) {
    @MockitoBean private lateinit var service: PushDiagnosticService
    @MockitoBean private lateinit var jwtService: JwtService
    @MockitoBean private lateinit var userRepository: UserRepository
    @MockitoBean private lateinit var adminProperties: AdminProperties

    @Test
    fun `default-off diagnostic route is unavailable after valid admin key`() {
        Mockito.`when`(adminProperties.apiKey).thenReturn(ADMIN_KEY)
        mockMvc.perform(
            post("/admin/push/diagnostic").header("X-Admin-Key", ADMIN_KEY)
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"userId":7,"installationId":"$INSTALLATION_ID","meetingId":42,"reminderOffsetMinutes":60,"mode":"SINGLE"}"""),
        ).andExpect(status().isNotFound).andExpect(jsonPath("$.code").value("NOT_FOUND"))
        Mockito.verifyNoInteractions(service)
    }
}
