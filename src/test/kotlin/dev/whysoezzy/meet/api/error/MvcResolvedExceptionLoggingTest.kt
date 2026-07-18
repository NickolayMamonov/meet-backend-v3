package dev.whysoezzy.meet.api.error

import ch.qos.logback.classic.Logger
import ch.qos.logback.classic.spi.ILoggingEvent
import ch.qos.logback.core.read.ListAppender
import dev.whysoezzy.meet.api.controller.AuthController
import dev.whysoezzy.meet.api.controller.MeetingController
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.security.AdminKeyAuthFilter
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.security.JwtAuthFilter
import dev.whysoezzy.meet.service.AuthService
import dev.whysoezzy.meet.service.MeetingService
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.context.annotation.ComponentScan.Filter
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.context.annotation.Import
import org.springframework.context.annotation.FilterType
import org.springframework.core.env.Environment
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
import org.springframework.test.context.TestPropertySource
import kotlin.test.assertEquals
import kotlin.test.assertFalse

@WebMvcTest(
    controllers = [AuthController::class, MeetingController::class],
    excludeFilters = [
        Filter(type = FilterType.ASSIGNABLE_TYPE, classes = [JwtAuthFilter::class, AdminKeyAuthFilter::class]),
    ],
)
@Import(
    ApiExceptionHandler::class,
    ApiErrorResponseWriter::class,
    MvcLoggingTestSecurityConfig::class,
    StorageProperties::class,
)
@TestPropertySource(properties = ["spring.mvc.log-resolved-exception=false"])
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class MvcResolvedExceptionLoggingTest(
    @Autowired private val mockMvc: MockMvc,
    @Autowired private val environment: Environment,
) {
    @MockBean
    private lateinit var authService: AuthService

    @MockBean
    private lateinit var authUtils: AuthUtils

    @MockBean
    private lateinit var meetingService: MeetingService

    @Test
    fun `default profile does not log rejected auth or MVC validation values`() {
        assertEquals("false", environment.getProperty("spring.mvc.log-resolved-exception"))

        val invalidAuthMarker = "invalid-auth-marker-7f3b"
        val validationMarker = "mvc-validation-marker-5d1e"
        val events = captureRootLogs {
            mockMvc.perform(
                post("/auth/send-otp")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("""{"phone":"$invalidAuthMarker"}"""),
            ).andExpectBadRequest("Phone must be in E.164 format", "/auth/send-otp")

            mockMvc.perform(
                get("/meetings/search").param("query", validationMarker.repeat(20)),
            ).andExpectBadRequest("Query must not exceed 200 characters", "/meetings/search")
        }

        assertNoMarkerInRootLogs(events, invalidAuthMarker, validationMarker)
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
            "${it.formattedMessage}\n${it.throwableProxy}"
        }
        markers.forEach { marker ->
            assertFalse(output.contains(marker), "root log output leaked '$marker': $output")
        }
    }
}

@Configuration
private class MvcLoggingTestSecurityConfig {
    @Bean
    fun mvcLoggingTestSecurityFilterChain(http: HttpSecurity): SecurityFilterChain =
        http
            .csrf { it.disable() }
            .authorizeHttpRequests {
                it.requestMatchers(HttpMethod.POST, "/auth/send-otp").permitAll()
                    .requestMatchers(HttpMethod.GET, "/meetings/search").permitAll()
                    .anyRequest().denyAll()
            }
            .build()
}
