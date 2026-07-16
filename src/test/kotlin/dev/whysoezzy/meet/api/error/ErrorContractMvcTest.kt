package dev.whysoezzy.meet.api.error

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import dev.whysoezzy.meet.api.controller.MeetingController
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.security.ApiAccessDeniedHandler
import dev.whysoezzy.meet.security.ApiAuthenticationEntryPoint
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.security.JwtService
import dev.whysoezzy.meet.service.MeetingService
import jakarta.validation.Valid
import jakarta.validation.constraints.NotBlank
import org.junit.jupiter.api.Test
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.context.annotation.Import
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.http.HttpMethod
import org.springframework.http.MediaType
import org.springframework.security.config.annotation.web.builders.HttpSecurity
import org.springframework.security.web.SecurityFilterChain
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.ResultActions
import org.springframework.test.web.servlet.ResultMatcher
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RestController
import java.time.Instant
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.`when`

@WebMvcTest(controllers = [ErrorContractController::class, MeetingController::class])
@Import(
    ApiExceptionHandler::class,
    ApiErrorResponseWriter::class,
    ApiAuthenticationEntryPoint::class,
    ApiAccessDeniedHandler::class,
    StorageProperties::class,
    ErrorContractSecurityConfig::class,
)
class ErrorContractMvcTest(
    @Autowired private val mockMvc: MockMvc,
) {
    @MockBean
    private lateinit var jwtService: JwtService

    @MockBean
    private lateinit var meetingService: MeetingService

    @MockBean
    private lateinit var authUtils: AuthUtils

    @Test
    fun `returns structured bad request validation error`() {
        mockMvc.perform(
            post("/contract/validated")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"name":""}"""),
        ).andExpectError(400, "Name is required", "/contract/validated", "BAD_REQUEST")
    }

    @Test
    fun `returns structured not found error`() {
        mockMvc.perform(get("/contract/not-found"))
            .andExpectError(404, "Resource not found", "/contract/not-found", "NOT_FOUND")
    }

    @Test
    fun `returns structured conflict when joining a full meeting`() {
        `when`(authUtils.getCurrentUserId()).thenReturn(42L)
        doThrow(ConflictException("Meeting is at full capacity"))
            .`when`(meetingService)
            .joinMeeting(99L, 42L)

        mockMvc.perform(post("/meetings/99/join").with(user("42")))
            .andExpectError(409, "Meeting is at full capacity", "/meetings/99/join", "CONFLICT")
    }

    @Test
    fun `returns structured unexpected error without implementation details`() {
        mockMvc.perform(get("/contract/failure"))
            .andExpectError(500, "An unexpected error occurred", "/contract/failure", "INTERNAL_ERROR")
    }

    @Test
    fun `returns structured unauthenticated security error`() {
        mockMvc.perform(get("/contract/protected"))
            .andExpectError(401, "Authentication is required", "/contract/protected", "UNAUTHORIZED")
    }

    @Test
    fun `returns structured forbidden security error`() {
        mockMvc.perform(get("/contract/admin").with(user("member").roles("USER")))
            .andExpectError(403, "Access is denied", "/contract/admin", "FORBIDDEN")
    }

    private fun ResultActions.andExpectError(
        expectedStatus: Int,
        expectedMessage: String,
        expectedPath: String,
        expectedCode: String,
    ): ResultActions = andExpect(status().`is`(expectedStatus))
        .andExpect(jsonPath("$.status").value(expectedStatus))
        .andExpect(jsonPath("$.message").value(expectedMessage))
        .andExpect(jsonPath("$.path").value(expectedPath))
        .andExpect(jsonPath("$.code").value(expectedCode))
        .andExpect(isoInstantTimestamp())

    private fun isoInstantTimestamp() = ResultMatcher { result ->
        val timestamp = jacksonObjectMapper()
            .readTree(result.response.contentAsString)
            .path("timestamp")
            .asText()
        Instant.parse(timestamp)
    }
}

@RestController
private class ErrorContractController {
    @PostMapping("/contract/validated")
    fun validate(@Valid @RequestBody request: ValidatedRequest) = request

    @GetMapping("/contract/not-found")
    fun notFound(): Nothing = throw NotFoundException("Resource not found")

    @GetMapping("/contract/failure")
    fun failure(): Nothing = throw IllegalStateException("sensitive implementation detail")

    @GetMapping("/contract/protected")
    fun protected() = "ok"

    @GetMapping("/contract/admin")
    fun admin() = "ok"
}

private data class ValidatedRequest(
    @field:NotBlank(message = "Name is required")
    val name: String,
)

@Configuration
private class ErrorContractSecurityConfig(
    private val apiAuthenticationEntryPoint: ApiAuthenticationEntryPoint,
    private val apiAccessDeniedHandler: ApiAccessDeniedHandler,
) {
    @Bean
    fun errorContractSecurityFilterChain(http: HttpSecurity): SecurityFilterChain =
        http
            .csrf { it.disable() }
            .authorizeHttpRequests {
                it.requestMatchers(HttpMethod.POST, "/contract/validated").permitAll()
                    .requestMatchers(
                        "/contract/not-found",
                        "/contract/failure",
                    ).permitAll()
                    .requestMatchers(HttpMethod.POST, "/meetings/*/join").authenticated()
                    .requestMatchers("/contract/admin").hasRole("ADMIN")
                    .requestMatchers("/contract/protected").authenticated()
                    .anyRequest().permitAll()
            }
            .exceptionHandling {
                it.authenticationEntryPoint(apiAuthenticationEntryPoint)
                    .accessDeniedHandler(apiAccessDeniedHandler)
            }
            .build()
}
