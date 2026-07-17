package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.api.controller.AdminController
import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import dev.whysoezzy.meet.config.AdminProperties
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.ingestion.IngestionService
import org.junit.jupiter.api.Test
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.context.annotation.Import
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.util.Optional

@WebMvcTest(controllers = [AdminController::class])
@Import(
    AdminKeyAuthFilter::class,
    JwtAuthFilter::class,
    SecurityConfig::class,
    ApiAuthenticationEntryPoint::class,
    ApiAccessDeniedHandler::class,
    ApiErrorResponseWriter::class,
    StorageProperties::class,
)
class AdminKeyAuthFilterMvcTest(
    @Autowired private val mockMvc: MockMvc,
) {
    @MockBean
    private lateinit var adminProperties: AdminProperties

    @MockBean
    private lateinit var jwtService: JwtService

    @MockBean
    private lateinit var userRepository: UserRepository

    @MockBean
    private lateinit var ingestionService: IngestionService

    @Test
    fun `rejects missing blank and incorrect keys on all admin endpoints`() {
        `when`(adminProperties.apiKey).thenReturn("test-admin-key")

        listOf(null, "", "wrong-key").forEach { key ->
            listOf(ingestRequest(), purgeRequest()).forEach { request ->
                key?.let { request.header("X-Admin-Key", it) }
                request.andExpectForbidden()
            }
        }
    }

    @Test
    fun `rejects valid keys when admin configuration is absent or blank on all admin endpoints`() {
        listOf("", "   ").forEach { configuredKey ->
            `when`(adminProperties.apiKey).thenReturn(configuredKey)

            listOf(ingestRequest(), purgeRequest()).forEach {
                it.header("X-Admin-Key", "test-admin-key").andExpectForbidden()
            }
        }
    }

    @Test
    fun `allows valid keys on all admin endpoints`() {
        `when`(adminProperties.apiKey).thenReturn("test-admin-key")
        `when`(ingestionService.runAll()).thenReturn(emptyList())
        `when`(ingestionService.purgePastEvents()).thenReturn(0)
        `when`(ingestionService.purgeBySource(EventSource.TIMEPAD)).thenReturn(3)

        mockMvc.perform(ingestRequest().header("X-Admin-Key", "test-admin-key"))
            .andExpect(status().isOk)

        mockMvc.perform(purgeRequest().header("X-Admin-Key", "test-admin-key"))
            .andExpect(status().isOk)
    }

    @Test
    fun `preserves invalid source response after valid admin authorization`() {
        `when`(adminProperties.apiKey).thenReturn("test-admin-key")

        mockMvc.perform(
            delete("/admin/purge")
                .header("X-Admin-Key", "test-admin-key")
                .param("source", "not-a-source"),
        )
            .andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.code").value("BAD_REQUEST"))
    }

    @Test
    fun `a JWT user cannot bypass the admin key gate`() {
        `when`(adminProperties.apiKey).thenReturn("test-admin-key")
        `when`(jwtService.validateToken("user-token")).thenReturn(true)
        `when`(jwtService.getUserIdFromToken("user-token")).thenReturn(1)
        `when`(jwtService.getAuthVersionFromToken("user-token")).thenReturn(2)
        `when`(userRepository.findById(1)).thenReturn(Optional.of(user(authVersion = 2)))

        purgeRequest()
            .header("Authorization", "Bearer user-token")
            .andExpectForbidden()
    }

    private fun ingestRequest() = post("/admin/ingest")

    private fun purgeRequest() = delete("/admin/purge").param("source", "timepad")

    private fun MockHttpServletRequestBuilder.andExpectForbidden() {
        mockMvc.perform(this)
            .andExpect(status().isForbidden)
            .andExpect(jsonPath("$.code").value("FORBIDDEN"))
    }

    private fun user(authVersion: Long) = User("Test", "User", "+79990000000").also {
        it.id = 1L
        it.authVersion = authVersion
    }
}
