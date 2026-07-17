package dev.whysoezzy.meet.security

import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.junit.jupiter.api.Test
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.security.config.annotation.web.builders.HttpSecurity
import org.springframework.security.web.SecurityFilterChain
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.content
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController

@WebMvcTest(controllers = [JwtAuthFilterProbeController::class])
@Import(
    JwtAuthFilter::class,
    ApiAuthenticationEntryPoint::class,
    ApiAccessDeniedHandler::class,
    ApiErrorResponseWriter::class,
    StorageProperties::class,
    JwtAuthFilterMvcTest.SecurityTestConfig::class,
)
class JwtAuthFilterMvcTest(
    @Autowired private val mockMvc: MockMvc,
) {
    @MockBean
    private lateinit var jwtService: JwtService

    @MockBean
    private lateinit var userRepository: UserRepository

    @Test
    fun `accepts valid JWT for active user`() {
        validTokenFor(42L)
        `when`(userRepository.existsByIdAndDeletedAtIsNull(42L)).thenReturn(true)

        mockMvc.perform(get(PROBE_PATH).header("Authorization", "Bearer valid-token"))
            .andExpect(status().isOk)
            .andExpect(content().string("ok"))
    }

    @Test
    fun `rejects valid JWT for soft-deleted user`() {
        validTokenFor(42L)
        `when`(userRepository.existsByIdAndDeletedAtIsNull(42L)).thenReturn(false)

        mockMvc.perform(get(PROBE_PATH).header("Authorization", "Bearer valid-token"))
            .andExpectUnauthorizedError()
    }

    @Test
    fun `rejects valid JWT for missing user`() {
        validTokenFor(99L)
        `when`(userRepository.existsByIdAndDeletedAtIsNull(99L)).thenReturn(false)

        mockMvc.perform(get(PROBE_PATH).header("Authorization", "Bearer valid-token"))
            .andExpectUnauthorizedError()
    }

    private fun validTokenFor(userId: Long) {
        `when`(jwtService.validateToken("valid-token")).thenReturn(true)
        `when`(jwtService.getUserIdFromToken("valid-token")).thenReturn(userId)
    }

    private fun org.springframework.test.web.servlet.ResultActions.andExpectUnauthorizedError() {
        andExpect(status().isUnauthorized)
            .andExpect(jsonPath("$.status").value(401))
            .andExpect(jsonPath("$.code").value("UNAUTHORIZED"))
            .andExpect(jsonPath("$.path").value(PROBE_PATH))
    }

    @TestConfiguration
    class SecurityTestConfig {
        @Bean
        fun securityFilterChain(
            http: HttpSecurity,
            jwtAuthFilter: JwtAuthFilter,
            apiAuthenticationEntryPoint: ApiAuthenticationEntryPoint,
            apiAccessDeniedHandler: ApiAccessDeniedHandler,
        ): SecurityFilterChain =
            http
                .csrf { it.disable() }
                .authorizeHttpRequests { it.anyRequest().authenticated() }
                .exceptionHandling {
                    it.authenticationEntryPoint(apiAuthenticationEntryPoint)
                        .accessDeniedHandler(apiAccessDeniedHandler)
                }
                .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter::class.java)
                .build()
    }

    private companion object {
        const val PROBE_PATH = "/jwt-auth-filter-probe"
    }
}

@RestController
private class JwtAuthFilterProbeController {
    @GetMapping("/jwt-auth-filter-probe")
    fun probe() = "ok"
}
