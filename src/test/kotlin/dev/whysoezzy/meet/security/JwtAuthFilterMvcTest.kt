package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.junit.jupiter.api.Test
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest
import org.springframework.context.annotation.Import
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController
import java.util.Optional

@WebMvcTest(controllers = [JwtAuthFilterProbeController::class])
@Import(
    JwtAuthFilter::class,
    SecurityConfig::class,
    ApiAuthenticationEntryPoint::class,
    ApiAccessDeniedHandler::class,
    ApiErrorResponseWriter::class,
    StorageProperties::class,
)
class JwtAuthFilterMvcTest @Autowired constructor(
    private val mockMvc: MockMvc,
) {
    @MockitoBean
    private lateinit var jwtService: JwtService

    @MockitoBean
    private lateinit var userRepository: UserRepository

    @Test
    fun `rejects a stale auth version JWT from a protected request`() {
        authenticateWith(token = "stale-token", tokenAuthVersion = 2, user = user(authVersion = 3))

        protectedRequest("stale-token")
    }

    @Test
    fun `rejects a soft deleted user JWT from a protected request`() {
        authenticateWith(
            token = "deleted-user-token",
            tokenAuthVersion = 2,
            user = user(authVersion = 2).also { it.deletedAt = java.time.LocalDateTime.now() },
        )

        protectedRequest("deleted-user-token")
    }

    private fun authenticateWith(token: String, tokenAuthVersion: Long, user: User) {
        `when`(jwtService.validateToken(token)).thenReturn(true)
        `when`(jwtService.getUserIdFromToken(token)).thenReturn(1L)
        `when`(jwtService.getAuthVersionFromToken(token)).thenReturn(tokenAuthVersion)
        `when`(userRepository.findById(1L)).thenReturn(Optional.of(user))
    }

    private fun protectedRequest(token: String) {
        mockMvc.perform(get("/jwt-filter-probe").header("Authorization", "Bearer $token"))
            .andExpect(status().isUnauthorized)
            .andExpect(jsonPath("$.code").value("UNAUTHORIZED"))
    }

    private fun user(authVersion: Long) = User("Test", "User", "+79990000000").also {
        it.id = 1L
        it.authVersion = authVersion
    }
}

@RestController
private class JwtAuthFilterProbeController {
    @GetMapping("/jwt-filter-probe")
    fun protectedProbe() = "authenticated"
}
