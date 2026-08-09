package dev.whysoezzy.meet.api.error

import ch.qos.logback.classic.Logger
import ch.qos.logback.classic.spi.ILoggingEvent
import ch.qos.logback.classic.spi.ThrowableProxyUtil
import ch.qos.logback.core.read.ListAppender
import dev.whysoezzy.meet.api.controller.AuthController
import dev.whysoezzy.meet.api.controller.MeetingController
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.security.AdminKeyAuthFilter
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.security.JwtAuthFilter
import dev.whysoezzy.meet.service.AuthService
import dev.whysoezzy.meet.service.MeetingService
import dev.whysoezzy.meet.service.auth.identifier.ClientRequestContextResolver
import dev.whysoezzy.meet.service.auth.identifier.DeviceIdParser
import dev.whysoezzy.meet.service.auth.identifier.EmailOtpRequestValidator
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.context.annotation.ComponentScan.Filter
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.context.annotation.FilterType
import org.springframework.http.HttpMethod
import org.springframework.http.MediaType
import org.springframework.security.config.annotation.web.builders.HttpSecurity
import org.springframework.security.web.SecurityFilterChain
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.ResultActions
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import kotlin.test.assertEquals
import kotlin.test.assertFalse

@WebMvcTest(
    controllers = [AuthController::class, MeetingController::class],
    excludeFilters = [
        Filter(
            type = FilterType.REGEX,
            pattern = ["dev\\.whysoezzy\\.meet\\.security\\.(JwtAuthFilter|AdminKeyAuthFilter)"],
        ),
    ],
)
@Import(
    ApiExceptionHandler::class,
    ApiErrorResponseWriter::class,
    MvcLoggingTestSecurityConfig::class,
    StorageProperties::class,
    DeviceIdParser::class,
    EmailOtpRequestValidator::class,
)
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class MvcResolvedExceptionLoggingTest @Autowired constructor(
    private val mockMvc: MockMvc,
) {
    @MockitoBean
    private lateinit var authService: AuthService

    @MockitoBean
    private lateinit var authUtils: AuthUtils

    @MockitoBean
    private lateinit var meetingService: MeetingService

    @MockitoBean
    private lateinit var clientRequestContextResolver: ClientRequestContextResolver

    @Test
    fun `default profile does not log rejected auth or MVC validation values`() {
        val invalidAuthMarker = "invalid-auth-marker-7f3b"
        val emailMarker = "email-marker-8f4c"
        val deviceMarker = "device-marker"
        val codeMarker = "code-marker"
        val validationMarker = "mvc-validation-marker-5d1e"
        val events = captureRootLogs {
            mockMvc.perform(
                post("/auth/send-otp")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("""{"phone":"$invalidAuthMarker"}"""),
            ).andExpectBadRequest("Phone must be in E.164 format", "/auth/send-otp")

            mockMvc.perform(
                post("/auth/email/send-otp")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("""{"email":"$emailMarker"}"""),
            ).andExpectBadRequest("Email must be valid", "/auth/email/send-otp")

            mockMvc.perform(
                post("/auth/email/verify-otp")
                    .header("X-Device-Id", deviceMarker)
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("""{"email":"person@example.com","code":"123456"}"""),
            ).andExpectBadRequest(
                "X-Device-Id must be 16 to 128 safe ASCII characters",
                "/auth/email/verify-otp",
            )

            mockMvc.perform(
                post("/auth/email/verify-otp")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("""{"email":"person@example.com","code":"$codeMarker"}"""),
            ).andExpectBadRequest("OTP code must be a six-digit number", "/auth/email/verify-otp")

            mockMvc.perform(
                get("/meetings/search").param("query", validationMarker.repeat(20)),
            ).andExpectBadRequest("Query must not exceed 200 characters", "/meetings/search")
        }

        assertNoMarkerInRootLogs(
            events,
            invalidAuthMarker,
            emailMarker,
            deviceMarker,
            codeMarker,
            validationMarker,
        )
    }

    private fun ResultActions.andExpectBadRequest(message: String, path: String): ResultActions =
        andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.status").value(400))
            .andExpect(jsonPath("$.code").value("BAD_REQUEST"))
            .andExpect(jsonPath("$.message").value(message))
            .andExpect(jsonPath("$.path").value(path))

    private fun captureRootLogs(action: () -> Unit): List<ILoggingEvent> {
        val rootLogger = LoggerFactory.getLogger(Logger.ROOT_LOGGER_NAME) as Logger
        val appender = ListAppender<ILoggingEvent>().apply { start() }
        rootLogger.addAppender(appender)
        try {
            action()
            return appender.list.toList()
        } finally {
            rootLogger.detachAppender(appender)
            appender.stop()
        }
    }

    private fun assertNoMarkerInRootLogs(events: List<ILoggingEvent>, vararg markers: String) {
        val output = events.joinToString("\n") {
            "${it.formattedMessage}\n${it.throwableProxy?.let(ThrowableProxyUtil::asString).orEmpty()}"
        }
        markers.forEach { marker ->
            assertFalse(output.contains(marker), "root log output leaked '$marker': $output")
        }
    }
}

@TestConfiguration
private class MvcLoggingTestSecurityConfig {
    @Bean
    fun mvcLoggingTestSecurityFilterChain(http: HttpSecurity): SecurityFilterChain =
        http
            .csrf { it.disable() }
            .authorizeHttpRequests {
                it.requestMatchers(HttpMethod.POST, "/auth/send-otp").permitAll()
                    .requestMatchers(HttpMethod.POST, "/auth/email/**").permitAll()
                    .requestMatchers(HttpMethod.GET, "/meetings/search").permitAll()
                    .anyRequest().denyAll()
            }
            .build()
}
