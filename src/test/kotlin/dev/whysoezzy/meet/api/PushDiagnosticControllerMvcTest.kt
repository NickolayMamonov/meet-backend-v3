package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.controller.AdminPushController
import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import dev.whysoezzy.meet.api.error.ApiExceptionHandler
import dev.whysoezzy.meet.config.PushWebConfiguration
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.config.AdminProperties
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.security.ApiAccessDeniedHandler
import dev.whysoezzy.meet.security.ApiAuthenticationEntryPoint
import dev.whysoezzy.meet.security.JwtService
import dev.whysoezzy.meet.service.push.DiagnosticAggregateResult
import dev.whysoezzy.meet.service.push.DiagnosticCallResult
import dev.whysoezzy.meet.service.push.PushDiagnosticCommand
import dev.whysoezzy.meet.service.push.PushDiagnosticMode
import dev.whysoezzy.meet.service.push.PushDiagnosticResponse
import dev.whysoezzy.meet.service.push.PushDiagnosticService
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest
import org.springframework.http.MediaType
import org.springframework.test.context.TestPropertySource
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.util.UUID
import kotlin.test.assertEquals

@WebMvcTest(controllers = [AdminPushController::class])
@org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc(addFilters = false)
@TestPropertySource(
    properties = [
        "app.push.provider-enabled=true",
        "app.push.diagnostic-enabled=true",
    ],
)
@org.springframework.context.annotation.Import(
    ApiExceptionHandler::class,
    ApiErrorResponseWriter::class,
    PushWebConfiguration::class,
    StorageProperties::class,
    ApiAuthenticationEntryPoint::class,
    ApiAccessDeniedHandler::class,
)
class PushDiagnosticControllerMvcTest @Autowired constructor(
    private val mockMvc: MockMvc,
) {
    @MockitoBean
    private lateinit var service: PushDiagnosticService

    @MockitoBean
    private lateinit var jwtService: JwtService

    @MockitoBean
    private lateinit var userRepository: UserRepository

    @MockitoBean
    private lateinit var adminProperties: AdminProperties

    private val installationId = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun `diagnostic serializes safe single and dedup pair categories through MVC`() {
        Mockito.`when`(adminProperties.apiKey).thenReturn("test-admin-key")
        val single = PushDiagnosticCommand(
            7,
            UUID.fromString(installationId),
            42,
            60,
            PushDiagnosticMode.SINGLE,
        )
        Mockito.`when`(service.send(single)).thenReturn(
            PushDiagnosticResponse.Single(DiagnosticCallResult.Accepted),
        )

        mockMvc.perform(
            post("/admin/push/diagnostic")
                .with(user("admin").roles("ADMIN"))
                .header("X-Admin-Key", "test-admin-key")
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    """{"userId":7,"installationId":"$installationId","meetingId":42,"reminderOffsetMinutes":60,"mode":"SINGLE"}""",
                ),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.result").value("ACCEPTED"))

        val pair = single.copy(mode = PushDiagnosticMode.DEDUP_PAIR)
        Mockito.`when`(service.send(pair)).thenReturn(
            PushDiagnosticResponse.Pair(
                DiagnosticAggregateResult.ACCEPTED_PAIR,
                DiagnosticCallResult.Accepted,
                DiagnosticCallResult.Accepted,
            ),
        )
        mockMvc.perform(
            post("/admin/push/diagnostic")
                .with(user("admin").roles("ADMIN"))
                .header("X-Admin-Key", "test-admin-key")
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    """{"userId":7,"installationId":"$installationId","meetingId":42,"reminderOffsetMinutes":60,"mode":"DEDUP_PAIR"}""",
                ),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.result").value("ACCEPTED_PAIR"))
            .andExpect(jsonPath("$.first").value("ACCEPTED"))
            .andExpect(jsonPath("$.second").value("ACCEPTED"))
    }

    @Test
    fun `diagnostic rejects query targeting and noncanonical request values`() {
        Mockito.`when`(adminProperties.apiKey).thenReturn("test-admin-key")
        val valid = """{"userId":7,"installationId":"$installationId","meetingId":42,"reminderOffsetMinutes":60,"mode":"SINGLE"}"""
        mockMvc.perform(
            post("/admin/push/diagnostic?topic=all")
                .with(user("admin").roles("ADMIN"))
                .header("X-Admin-Key", "test-admin-key")
                .contentType(MediaType.APPLICATION_JSON)
                .content(valid),
        )
            .andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.code").value("BAD_REQUEST"))

        listOf(
            valid.replace("\"userId\":7", "\"userId\":0"),
            valid.replace(installationId, installationId.uppercase()),
            valid.replace("\"reminderOffsetMinutes\":60", "\"reminderOffsetMinutes\":30"),
        ).forEach { body ->
            mockMvc.perform(
                post("/admin/push/diagnostic")
                    .with(user("admin").roles("ADMIN"))
                    .header("X-Admin-Key", "test-admin-key")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(body),
            )
                .andExpect(status().isBadRequest)
                .andExpect(jsonPath("$.code").value("BAD_REQUEST"))
        }
        assertEquals(0, Mockito.mockingDetails(service).invocations.count { it.method.name == "send" })
    }
}
