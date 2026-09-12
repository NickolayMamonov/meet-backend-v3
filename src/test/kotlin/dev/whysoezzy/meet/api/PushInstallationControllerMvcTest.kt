package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.controller.PushInstallationController
import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import dev.whysoezzy.meet.api.error.ApiExceptionHandler
import dev.whysoezzy.meet.config.PushWebConfiguration
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.ApiAccessDeniedHandler
import dev.whysoezzy.meet.security.ApiAuthenticationEntryPoint
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.security.JwtService
import dev.whysoezzy.meet.service.push.InstallationStatus
import dev.whysoezzy.meet.service.push.PushFid
import dev.whysoezzy.meet.service.push.PushInstallationMutation
import dev.whysoezzy.meet.service.push.PushInstallationRecord
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest
import org.springframework.http.MediaType
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals

@WebMvcTest(controllers = [PushInstallationController::class])
@org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc(addFilters = false)
@org.springframework.context.annotation.Import(
    ApiExceptionHandler::class,
    ApiErrorResponseWriter::class,
    PushWebConfiguration::class,
    StorageProperties::class,
    ApiAuthenticationEntryPoint::class,
    ApiAccessDeniedHandler::class,
)
class PushInstallationControllerMvcTest @Autowired constructor(
    private val mockMvc: MockMvc,
) {
    @MockitoBean
    private lateinit var auth: AuthUtils

    @MockitoBean
    private lateinit var service: PushInstallationService

    @MockitoBean
    private lateinit var jwtService: JwtService

    @MockitoBean
    private lateinit var userRepository: UserRepository

    private val installationId = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
    private val seenAt = Instant.parse("2026-09-11T20:00:00Z")

    @Test
    fun `register returns created then OK while forwarding the authenticated owner and parsed FID`() {
        Mockito.`when`(auth.getCurrentUserId()).thenReturn(7L)
        val active = record(installationId, 7L)
        val calls = AtomicInteger()
        Mockito.doAnswer { invocation ->
            assertEquals(7L, invocation.getArgument<Long>(0))
            assertEquals("fid-1", invocation.getArgument<PushFid>(1).value)
            PushInstallationMutation(active, created = calls.getAndIncrement() == 0)
        }.`when`(service).register(
            Mockito.anyLong(),
            Mockito.any(PushFid::class.java) ?: parseFid("matcher"),
        )

        mockMvc.perform(
            post("/profile/push-installations")
                .with(user("7").roles("USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fid":"fid-1"}"""),
        )
            .andExpect(status().isCreated)
            .andExpect(jsonPath("$.installationId").value(installationId.toString()))
            .andExpect(jsonPath("$.status").value("ACTIVE"))

        mockMvc.perform(
            post("/profile/push-installations")
                .with(user("7").roles("USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fid":"fid-1"}"""),
        ).andExpect(status().isOk)
        Mockito.verify(auth, Mockito.times(2)).getCurrentUserId()
    }

    @Test
    fun `rotate and delete work through MVC and malformed IDs are structured bad requests`() {
        Mockito.`when`(auth.getCurrentUserId()).thenReturn(7L)
        Mockito.`when`(
            service.rotate(
                Mockito.anyLong(),
                Mockito.eq(installationId) ?: installationId,
                Mockito.any(PushFid::class.java) ?: parseFid("matcher"),
            ),
        ).thenReturn(PushInstallationMutation(record(installationId, 7L)))

        mockMvc.perform(
            put("/profile/push-installations/$installationId")
                .with(user("7").roles("USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fid":"fid-2"}"""),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.installationId").value(installationId.toString()))

        mockMvc.perform(
            delete("/profile/push-installations/$installationId").with(user("7").roles("USER")),
        )
            .andExpect(status().isNoContent)

        mockMvc.perform(
            put("/profile/push-installations/${installationId.toString().uppercase()}")
                .with(user("7").roles("USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fid":"fid-2"}"""),
        )
            .andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.code").value("BAD_REQUEST"))

        mockMvc.perform(
            post("/profile/push-installations")
                .with(user("7").roles("USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fid":""}"""),
        )
            .andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.code").value("BAD_REQUEST"))
    }

    @Test
    fun `vendor JSON media types cannot bypass the strict push request converter`() {
        mockMvc.perform(
            post("/profile/push-installations")
                .with(user("7").roles("USER"))
                .contentType("application/vnd.example+json")
                .content("""{"fid":"fid-1","unknown":"rejected"}"""),
        )
            .andExpect(status().isUnsupportedMediaType)
        Mockito.verifyNoInteractions(service)
    }

    private fun record(id: UUID, userId: Long) = PushInstallationRecord(
        id = id,
        userId = userId,
        fid = parseFid("fid-1"),
        status = InstallationStatus.ACTIVE,
        registrationVersion = 1,
        createdAt = seenAt,
        updatedAt = seenAt,
        lastSeenAt = seenAt,
        terminalAt = null,
    )
}
