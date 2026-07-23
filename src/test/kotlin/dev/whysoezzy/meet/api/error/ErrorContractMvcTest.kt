package dev.whysoezzy.meet.api.error

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import dev.whysoezzy.meet.api.controller.AdminController
import dev.whysoezzy.meet.api.controller.AuthController
import dev.whysoezzy.meet.api.controller.CommunityController
import dev.whysoezzy.meet.api.controller.MeetingController
import dev.whysoezzy.meet.api.controller.MediaController
import dev.whysoezzy.meet.api.controller.UserController
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.ingestion.IngestionService
import dev.whysoezzy.meet.security.ApiAccessDeniedHandler
import dev.whysoezzy.meet.security.ApiAuthenticationEntryPoint
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.security.JwtService
import dev.whysoezzy.meet.service.MeetingService
import dev.whysoezzy.meet.service.CommunityService
import dev.whysoezzy.meet.service.AuthService
import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.StorageService
import dev.whysoezzy.meet.service.AvatarReplacementService
import dev.whysoezzy.meet.service.UserService
import jakarta.validation.Valid
import jakarta.validation.constraints.NotBlank
import org.junit.jupiter.api.Test
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.boot.test.context.TestConfiguration
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
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.header
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RestController
import java.time.Instant
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`

@WebMvcTest(
    controllers = [
        ErrorContractController::class,
        AuthController::class,
        CommunityController::class,
        MeetingController::class,
        UserController::class,
        MediaController::class,
        AdminController::class,
    ],
)
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
    private lateinit var communityService: CommunityService

    @MockBean
    private lateinit var authService: AuthService

    @MockBean
    private lateinit var authUtils: AuthUtils

    @MockBean
    private lateinit var userService: UserService

    @MockBean
    private lateinit var storageService: StorageService

    @MockBean
    private lateinit var avatarReplacementService: AvatarReplacementService

    @MockBean
    private lateinit var userRepository: UserRepository

    @MockBean
    private lateinit var ingestionService: IngestionService

    @Test
    fun `returns structured bad request validation error`() {
        mockMvc.perform(
            post("/contract/validated")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"name":""}"""),
        ).andExpectError(400, "Name is required", "/contract/validated", "BAD_REQUEST")
    }

    @Test
    fun `returns structured bad request for missing required query parameter`() {
        mockMvc.perform(get("/meetings/search"))
            .andExpectError(400, "Invalid request", "/meetings/search", "BAD_REQUEST")
    }

    @Test
    fun `accepts a normal meeting search term and rejects blank or oversized terms`() {
        `when`(authUtils.getCurrentUserIdOrNull()).thenReturn(null)
        `when`(meetingService.searchMeetings("coffee", null)).thenReturn(emptyList())

        mockMvc.perform(get("/meetings/search").param("query", "coffee"))
            .andExpect(status().isOk)
        verify(meetingService).searchMeetings("coffee", null)

        mockMvc.perform(get("/meetings/search").param("query", "   "))
            .andExpectError(400, "Query is required", "/meetings/search", "BAD_REQUEST")

        mockMvc.perform(get("/meetings/search").param("query", "a".repeat(201)))
            .andExpectError(400, "Query must not exceed 200 characters", "/meetings/search", "BAD_REQUEST")
    }

    @Test
    fun `returns structured not found error`() {
        mockMvc.perform(get("/contract/not-found"))
            .andExpectError(404, "Resource not found", "/contract/not-found", "NOT_FOUND")
    }

    @Test
    fun `returns structured typed application errors`() {
        mapOf(
            "/contract/bad-request" to ErrorExpectation(400, "Bad request", "BAD_REQUEST"),
            "/contract/unauthorized" to ErrorExpectation(401, "Authentication is required", "UNAUTHORIZED"),
            "/contract/forbidden" to ErrorExpectation(403, "Access is denied", "FORBIDDEN"),
            "/contract/not-found" to ErrorExpectation(404, "Resource not found", "NOT_FOUND"),
            "/contract/conflict" to ErrorExpectation(409, "State conflict", "CONFLICT"),
            "/contract/rate-limited" to ErrorExpectation(429, "Too many OTP requests. Please try again later.", "RATE_LIMITED"),
            "/contract/service-unavailable" to ErrorExpectation(503, "SMS delivery is not configured", "SMS_UNAVAILABLE"),
        ).forEach { (path, expected) ->
            mockMvc.perform(get(path))
                .andExpectError(expected.status, expected.message, path, expected.code)
        }
    }

    @Test
    fun `returns structured not found error for unmatched route`() {
        mockMvc.perform(get("/unknown-review-probe"))
            .andExpectError(404, "Resource not found", "/unknown-review-probe", "NOT_FOUND")
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

    @Test
    fun `returns OTP rate limit without inaccurate retry guidance`() {
        doThrow(RateLimitException("Too many OTP requests. Please try again later."))
            .`when`(authService)
            .sendOtp(
                org.mockito.ArgumentMatchers.eq("+79990000000") ?: "",
                org.mockito.ArgumentMatchers.any(OtpRequestContext::class.java),
            )

        mockMvc.perform(
            post("/auth/send-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+79990000000"}"""),
        )
            .andExpectError(
                429,
                "Too many OTP requests. Please try again later.",
                "/auth/send-otp",
                "RATE_LIMITED",
            )
            .andExpect(header().doesNotExist("Retry-After"))
    }

    @Test
    fun `returns a structured service unavailable response when SMS delivery is disabled`() {
        doThrow(ServiceUnavailableException("SMS delivery is not configured"))
            .`when`(authService)
            .sendOtp(
                org.mockito.ArgumentMatchers.eq("+79990000000") ?: "",
                org.mockito.ArgumentMatchers.any(OtpRequestContext::class.java),
            )

        mockMvc.perform(
            post("/auth/send-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+79990000000"}"""),
        ).andExpectError(503, "SMS delivery is not configured", "/auth/send-otp", "SMS_UNAVAILABLE")
    }

    @Test
    fun `rejects invalid auth payloads with structured errors`() {
        mockMvc.perform(
            post("/auth/send-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"79990000000"}"""),
        ).andExpectError(400, "Phone must be in E.164 format", "/auth/send-otp", "BAD_REQUEST")

        mockMvc.perform(
            post("/auth/verify-otp")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"phone":"+79990000000","code":"abc"}"""),
        ).andExpectError(400, "OTP code must be a six-digit number", "/auth/verify-otp", "BAD_REQUEST")
    }

    @Test
    fun `rejects invalid profile email and FCM token with structured errors`() {
        mockMvc.perform(
            org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put("/profile")
                .with(user("42"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email":"not-an-email"}"""),
        ).andExpectError(400, "Email must be valid", "/profile", "BAD_REQUEST")

        mockMvc.perform(
            org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put("/profile/fcm-token")
                .with(user("42"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"fcmToken":""}"""),
        ).andExpectError(400, "FCM token is required", "/profile/fcm-token", "BAD_REQUEST")
    }

    @Test
    fun `rejects non-positive profile interest IDs with structured error`() {
        mockMvc.perform(
            org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put("/profile")
                .with(user("42"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"interestIds":[0]}"""),
        ).andExpectError(400, "Interest IDs must be positive", "/profile", "BAD_REQUEST")

        mockMvc.perform(
            org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put("/profile")
                .with(user("42"))
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"interestIds":[-1]}"""),
        ).andExpectError(400, "Interest IDs must be positive", "/profile", "BAD_REQUEST")
    }

    @Test
    fun `rejects invalid pagination with structured errors`() {
        mockMvc.perform(get("/meetings").param("page", "-1"))
            .andExpectError(400, "Page must be zero or greater", "/meetings", "BAD_REQUEST")

        mockMvc.perform(get("/meetings").param("limit", "101"))
            .andExpectError(400, "Limit must not exceed 100", "/meetings", "BAD_REQUEST")
    }

    @Test
    fun `rejects blank and oversized community search queries with structured errors`() {
        mockMvc.perform(get("/communities/search").param("query", "   "))
            .andExpectError(400, "Query is required", "/communities/search", "BAD_REQUEST")

        mockMvc.perform(get("/communities/search").param("query", "a".repeat(201)))
            .andExpectError(400, "Query must not exceed 200 characters", "/communities/search", "BAD_REQUEST")
    }

    @Test
    fun `rejects missing and empty avatar upload with structured errors`() {
        mockMvc.perform(multipart("/media/avatar").with(user("42")))
            .andExpectError(400, "Invalid request", "/media/avatar", "BAD_REQUEST")

        mockMvc.perform(
            multipart("/media/avatar")
                .file("file", ByteArray(0))
                .with(user("42")),
        ).andExpectError(400, "File is empty", "/media/avatar", "BAD_REQUEST")
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

private data class ErrorExpectation(val status: Int, val message: String, val code: String)

@RestController
private class ErrorContractController {
    @PostMapping("/contract/validated")
    fun validate(@Valid @RequestBody request: ValidatedRequest) = request

    @GetMapping("/contract/not-found")
    fun notFound(): Nothing = throw NotFoundException("Resource not found")

    @GetMapping("/contract/bad-request")
    fun badRequest(): Nothing = throw BadRequestException("Bad request")

    @GetMapping("/contract/unauthorized")
    fun unauthorized(): Nothing = throw UnauthorizedException()

    @GetMapping("/contract/forbidden")
    fun forbidden(): Nothing = throw ForbiddenException()

    @GetMapping("/contract/conflict")
    fun conflict(): Nothing = throw ConflictException("State conflict")

    @GetMapping("/contract/rate-limited")
    fun rateLimited(): Nothing = throw RateLimitException("Too many OTP requests. Please try again later.")

    @GetMapping("/contract/service-unavailable")
    fun serviceUnavailable(): Nothing = throw ServiceUnavailableException("SMS delivery is not configured")

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

@TestConfiguration
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
                        "/contract/bad-request",
                        "/contract/unauthorized",
                        "/contract/forbidden",
                        "/contract/not-found",
                        "/contract/conflict",
                        "/contract/rate-limited",
                        "/contract/service-unavailable",
                        "/contract/failure",
                        "/auth/send-otp",
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
