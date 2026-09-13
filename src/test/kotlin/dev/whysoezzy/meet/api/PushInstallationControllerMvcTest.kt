package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.controller.PushInstallationController
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
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.*
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Optional
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals

@WebMvcTest(controllers = [PushInstallationController::class])
@Import(
    ApiExceptionHandler::class,
    ApiErrorResponseWriter::class,
    AuthUtils::class,
    PushWebConfiguration::class,
    StorageProperties::class,
    ApiAuthenticationEntryPoint::class,
    ApiAccessDeniedHandler::class,
    AdminKeyAuthFilter::class,
    JwtAuthFilter::class,
    SecurityConfig::class,
)
class PushInstallationControllerMvcTest @Autowired constructor(private val mockMvc: MockMvc) {
    @MockitoBean private lateinit var service: PushInstallationService
    @MockitoBean private lateinit var jwtService: JwtService
    @MockitoBean private lateinit var userRepository: UserRepository
    @MockitoBean private lateinit var adminProperties: AdminProperties

    private val id = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
    private val seenAt = Instant.parse("2026-09-11T20:00:00Z")

    @BeforeEach
    fun authenticateOwner() = authenticate("valid-token", 7, 3, 3)

    @Test
    fun `JWT owner lifecycle has exact statuses bodies and service arguments`() {
        val calls = AtomicInteger()
        Mockito.doAnswer {
            assertEquals(7L, it.getArgument<Long>(0))
            assertEquals("fid-1", it.getArgument<PushFid>(1).value)
            PushInstallationMutation(record("fid-1"), created = calls.getAndIncrement() == 0)
        }.`when`(service).register(Mockito.anyLong(), anyFid())
        Mockito.doAnswer {
            assertEquals(7L, it.getArgument<Long>(0))
            assertEquals(id, it.getArgument<UUID>(1))
            assertEquals("fid-2", it.getArgument<PushFid>(2).value)
            PushInstallationMutation(record("fid-2"))
        }.`when`(service).rotate(Mockito.anyLong(), anyUuid(), anyFid())

        mockMvc.perform(register("""{"fid":"fid-1"}""")).andExpect(status().isCreated).andExpectInstallation()
        mockMvc.perform(register("""{"fid":"fid-1"}""")).andExpect(status().isOk).andExpectInstallation()
        mockMvc.perform(rotate(id.toString(), """{"fid":"fid-2"}""")).andExpect(status().isOk).andExpectInstallation()
        mockMvc.perform(unregister(id.toString())).andExpect(status().isNoContent).andExpect(content().string(""))
        Mockito.verify(service).unregister(7, id)
    }

    @Test
    fun `real JWT filter rejects missing invalid unknown stale and deleted owners`() {
        Mockito.`when`(jwtService.validateToken("invalid")).thenReturn(false)
        Mockito.`when`(jwtService.validateToken("no-version")).thenReturn(true)
        Mockito.`when`(jwtService.getUserIdFromToken("no-version")).thenReturn(7)
        Mockito.`when`(jwtService.getAuthVersionFromToken("no-version")).thenReturn(null)
        Mockito.`when`(jwtService.validateToken("unknown")).thenReturn(true)
        Mockito.`when`(jwtService.getUserIdFromToken("unknown")).thenReturn(404)
        Mockito.`when`(jwtService.getAuthVersionFromToken("unknown")).thenReturn(1)
        Mockito.`when`(userRepository.findById(404)).thenReturn(Optional.empty())
        authenticate("stale", 8, 1, 2)
        authenticate("deleted", 9, 1, 1, deleted = true)

        listOf(
            register("""{"fid":"fid"}""", null).header("X-Admin-Key", "not-profile-auth"),
            register("""{"fid":"fid"}""", null).header("Authorization", "Basic credentials"),
            register("""{"fid":"fid"}""", "invalid"),
            register("""{"fid":"fid"}""", "no-version"),
            register("""{"fid":"fid"}""", "unknown"),
            register("""{"fid":"fid"}""", "stale"),
            register("""{"fid":"fid"}""", "deleted"),
        ).forEach {
            mockMvc.perform(it).andExpect(status().isUnauthorized).andExpect(jsonPath("$.code").value("UNAUTHORIZED"))
        }
        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `unknown and not-owned rows are indistinguishable`() {
        listOf(
            UUID.fromString("223e4567-e89b-12d3-a456-426614174000"),
            UUID.fromString("323e4567-e89b-12d3-a456-426614174000"),
        ).forEach { target ->
            Mockito.doThrow(NotFoundException("Push installation not found"))
                .`when`(service).rotate(Mockito.eq(7L), Mockito.eq(target) ?: target, anyFid())
            Mockito.doThrow(NotFoundException("Push installation not found"))
                .`when`(service).unregister(7, target)
            listOf(rotate(target.toString(), """{"fid":"next"}"""), unregister(target.toString())).forEach {
                mockMvc.perform(it)
                    .andExpect(status().isNotFound)
                    .andExpect(jsonPath("$.code").value("NOT_FOUND"))
                    .andExpect(jsonPath("$.message").value("Push installation not found"))
                    .andExpect(jsonPath("$.fid").doesNotExist())
            }
        }
    }

    @Test
    fun `conflict and retry exhaustion are distinct sanitized envelopes`() {
        val conflict = parseFid("conflicting-fid")
        val unavailable = parseFid("retry-exhausted-fid")
        Mockito.doThrow(PushConflictException()).`when`(service).register(7, conflict)
        Mockito.doThrow(PushUnavailableException()).`when`(service).register(7, unavailable)
        Mockito.doThrow(PushConflictException()).`when`(service).rotate(7, id, conflict)
        Mockito.doThrow(PushUnavailableException()).`when`(service).rotate(7, id, unavailable)

        listOf(
            register("""{"fid":"${conflict.value}"}""") to Triple(409, "CONFLICT_BLOCKED", "Push operation is blocked"),
            rotate(id.toString(), """{"fid":"${conflict.value}"}""") to Triple(409, "CONFLICT_BLOCKED", "Push operation is blocked"),
            register("""{"fid":"${unavailable.value}"}""") to Triple(503, "PUSH_UNAVAILABLE", "Push service is temporarily unavailable"),
            rotate(id.toString(), """{"fid":"${unavailable.value}"}""") to Triple(503, "PUSH_UNAVAILABLE", "Push service is temporarily unavailable"),
        ).forEach { (request, expected) ->
            mockMvc.perform(request)
                .andExpect { assertEquals(expected.first, it.response.status) }
                .andExpect(jsonPath("$.*", hasSize<Any>(5)))
                .andExpect(jsonPath("$.code").value(expected.second))
                .andExpect(jsonPath("$.message").value(expected.third))
                .andExpect(jsonPath("$.fid").doesNotExist())
        }
    }

    @Test
    fun `strict JSON rejects unknown duplicate coercion trailing malformed and oversize bodies`() {
        listOf(
            """{"fid":"fid","extra":true}""", """{"fid":"a","fid":"b"}""", """{}""",
            """{"fid":null}""", """{"fid":7}""", """{"fid":true}""", """{"fid":["fid"]}""",
            """"fid"""", """[]""", """{"fid":"fid"} {}""", """{"fid":""",
        ).forEach {
            mockMvc.perform(register(it)).andExpect(status().isBadRequest).andExpect(jsonPath("$.code").value("BAD_REQUEST"))
        }
        mockMvc.perform(register("""{"fid":"${"x".repeat(16 * 1024)}"}"""))
            .andExpect(status().`is`(HttpStatus.PAYLOAD_TOO_LARGE.value()))
            .andExpect(jsonPath("$.code").value("PAYLOAD_TOO_LARGE"))
        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `FID enforces exact UTF-8 and NUL boundaries without trimming`() {
        val accepted = listOf("x".repeat(1024), "é".repeat(512), "🚀".repeat(256), " fid ")
        Mockito.doAnswer {
            val fid = it.getArgument<PushFid>(1)
            PushInstallationMutation(record(fid.value), created = true)
        }.`when`(service).register(Mockito.eq(7L), anyFid())
        accepted.forEach {
            mockMvc.perform(register("""{"fid":${json(it)}}""")).andExpect(status().isCreated)
        }
        listOf("", " \t\r\n ", "x".repeat(1025), "é".repeat(513), "a\u0000b", "\uD800").forEach {
            mockMvc.perform(register("""{"fid":${json(it)}}"""))
                .andExpect(status().isBadRequest).andExpect(jsonPath("$.code").value("BAD_REQUEST"))
        }
        val invalidUtf8 = "{\"fid\":\"".toByteArray(StandardCharsets.US_ASCII) +
            byteArrayOf(0xC3.toByte(), 0x28) + "\"}".toByteArray(StandardCharsets.US_ASCII)
        mockMvc.perform(register(invalidUtf8)).andExpect(status().isBadRequest)
        assertEquals(
            accepted,
            Mockito.mockingDetails(service).invocations.filter { it.method.name == "register" }
                .map { (it.arguments[1] as PushFid).value },
        )
    }

    @Test
    fun `media type and canonical UUID paths cannot bypass validation`() {
        mockMvc.perform(
            post("/profile/push-installations").header("Authorization", "Bearer valid-token")
                .contentType("application/vnd.example+json").content("""{"fid":"fid","extra":true}"""),
        ).andExpect(status().isUnsupportedMediaType)
        listOf(id.toString().uppercase(), "123e4567-e89b-12d3-a456-42661417400", "not-a-uuid").forEach {
            mockMvc.perform(rotate(it, """{"fid":"fid"}""")).andExpect(status().isBadRequest)
            mockMvc.perform(unregister(it)).andExpect(status().isBadRequest)
        }
        Mockito.verifyNoInteractions(service)
    }

    @Test
    fun `unknown route is 404 and unsupported methods retain the existing global error envelope`() {
        mockMvc.perform(
            post("/profile/push-installations/unknown/route")
                .header("Authorization", "Bearer valid-token")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fid":"fid"}"""),
        )
            .andExpect(status().isNotFound)
            .andExpect(jsonPath("$.code").value("NOT_FOUND"))

        // ApiExceptionHandler currently handles method mismatches through its
        // existing generic exception boundary; this test records that route contract.
        listOf(
            get("/profile/push-installations").header("Authorization", "Bearer valid-token"),
            post("/profile/push-installations/$id")
                .header("Authorization", "Bearer valid-token")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fid":"fid"}"""),
        ).forEach {
            mockMvc.perform(it)
                .andExpect(status().isInternalServerError)
                .andExpect(jsonPath("$.code").value("INTERNAL_ERROR"))
        }
        Mockito.verifyNoInteractions(service)
    }

    private fun register(body: String, token: String? = "valid-token") =
        register(body.toByteArray(StandardCharsets.UTF_8), token)
    private fun register(body: ByteArray, token: String? = "valid-token") =
        post("/profile/push-installations").apply { token?.let { header("Authorization", "Bearer $it") } }
            .contentType(MediaType.APPLICATION_JSON).content(body)
    private fun rotate(target: String, body: String) =
        put("/profile/push-installations/$target").header("Authorization", "Bearer valid-token")
            .contentType(MediaType.APPLICATION_JSON).content(body)
    private fun unregister(target: String) =
        delete("/profile/push-installations/$target").header("Authorization", "Bearer valid-token")

    private fun org.springframework.test.web.servlet.ResultActions.andExpectInstallation() = this
        .andExpect(jsonPath("$.*", hasSize<Any>(3)))
        .andExpect(jsonPath("$.installationId").value(id.toString()))
        .andExpect(jsonPath("$.status").value("ACTIVE"))
        .andExpect(jsonPath("$.lastSeenAt").value("2026-09-11T20:00:00Z"))
        .andExpect(jsonPath("$.fid").doesNotExist())

    private fun authenticate(token: String, userId: Long, tokenVersion: Long, userVersion: Long, deleted: Boolean = false) {
        Mockito.`when`(jwtService.validateToken(token)).thenReturn(true)
        Mockito.`when`(jwtService.getUserIdFromToken(token)).thenReturn(userId)
        Mockito.`when`(jwtService.getAuthVersionFromToken(token)).thenReturn(tokenVersion)
        Mockito.`when`(userRepository.findById(userId)).thenReturn(Optional.of(User("Test", "User", "+79990000000").also {
            it.id = userId
            it.authVersion = userVersion
            if (deleted) it.deletedAt = java.time.LocalDateTime.parse("2026-09-11T20:00:00")
        }))
    }

    private fun record(fid: String) = PushInstallationRecord(
        id, 7, parseFid(fid), InstallationStatus.ACTIVE, 1, seenAt, seenAt, seenAt, null,
    )
    private fun anyFid(): PushFid = Mockito.any(PushFid::class.java) ?: parseFid("matcher")
    private fun anyUuid(): UUID = Mockito.any(UUID::class.java) ?: id
    private fun json(value: String) = buildString {
        append('"')
        value.forEach {
            when (it) {
                '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n")
                '\r' -> append("\\r"); '\t' -> append("\\t")
                else -> if (it.code < 0x20 || it.isSurrogate()) append("\\u${it.code.toString(16).padStart(4, '0')}") else append(it)
            }
        }
        append('"')
    }
}
