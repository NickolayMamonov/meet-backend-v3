package dev.whysoezzy.meet

import ch.qos.logback.classic.Level
import ch.qos.logback.classic.Logger
import ch.qos.logback.classic.spi.ILoggingEvent
import ch.qos.logback.classic.spi.ThrowableProxyUtil
import ch.qos.logback.core.read.ListAppender
import com.fasterxml.jackson.databind.ObjectMapper
import com.sun.net.httpserver.HttpServer
import org.yaml.snakeyaml.Yaml
import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import dev.whysoezzy.meet.api.error.ApiExceptionHandler
import dev.whysoezzy.meet.config.EmailProperties
import dev.whysoezzy.meet.config.EmailProvider
import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.JwtProperties
import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import dev.whysoezzy.meet.config.OtpVerificationProperties
import dev.whysoezzy.meet.config.RuntimeConfigurationInitializer
import dev.whysoezzy.meet.config.SmtpRuntimeSettings
import dev.whysoezzy.meet.config.StorageProperties
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.ingestion.EventProvider
import dev.whysoezzy.meet.ingestion.GeocodingService
import dev.whysoezzy.meet.ingestion.IngestionService
import dev.whysoezzy.meet.ingestion.MeetingUpsertService
import dev.whysoezzy.meet.security.JwtService
import dev.whysoezzy.meet.service.StorageService
import dev.whysoezzy.meet.service.UploadResult
import dev.whysoezzy.meet.service.auth.otp.OtpAttemptCleanupJob
import dev.whysoezzy.meet.service.auth.otp.OtpAttemptStore
import dev.whysoezzy.meet.service.auth.otp.OtpChallengeCleanupJob
import dev.whysoezzy.meet.service.auth.otp.OtpChallengeStore
import dev.whysoezzy.meet.service.email.EmailOtpMessage
import dev.whysoezzy.meet.service.email.SmtpEmailOtpSender
import jakarta.mail.internet.MimeMessage
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.ArgumentMatchers.anyLong
import org.mockito.ArgumentMatchers.isNull
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.ObjectProvider
import org.springframework.context.support.GenericApplicationContext
import org.springframework.core.env.MapPropertySource
import org.springframework.mock.web.MockHttpServletRequest
import org.springframework.mock.env.MockEnvironment
import org.springframework.mail.MailSendException
import org.springframework.mail.javamail.JavaMailSenderImpl
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.support.SimpleTransactionStatus
import org.springframework.web.client.RestClient
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.nio.file.Path
import java.util.Base64
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RuntimeLoggingSafetyTest {

    @ParameterizedTest(name = "{0} profile")
    @ValueSource(strings = ["default", "dev"])
    fun `invalid JWT is not emitted at either configured application log level`(profile: String) {
        val markers = listOf(
            SensitiveMarker("access token", "access-token-marker-$profile"),
            SensitiveMarker("refresh token", "refresh-token-marker-$profile"),
        )
        val events = captureApplicationLogs(profile) {
            val service = JwtService(JwtProperties(secret = "test-jwt-signing-secret-that-is-at-least-32-bytes"))
            markers.forEach { marker -> service.validateToken(marker.value) }
        }

        assertSafeEvent(events, "JWT validation failed", *markers.toTypedArray())
    }

    @ParameterizedTest(name = "{0} profile")
    @ValueSource(strings = ["default", "dev"])
    fun `failed geocoding does not emit supplied address or failure details`(profile: String) {
        val addressMarker = "address-marker-$profile"
        val exceptionMarker = "geocoder-exception-marker-$profile"
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            exchange.responseHeaders.add("X-Provider-Trace", "provider-header-marker-$profile")
            exchange.responseHeaders.add("X-Message-Id", "message-id-marker-$profile")
            exchange.sendResponseHeaders(500, exceptionMarker.length.toLong())
            exchange.responseBody.use { it.write(exceptionMarker.toByteArray()) }
        }
        server.start()

        try {
            val events = captureApplicationLogs(profile) {
                GeocodingService(
                    RestClient.builder(),
                    GeocoderProperties(
                        enabled = true,
                        apiKey = "geocoder-key-marker-$profile",
                        baseUrl = "http://127.0.0.1:${server.address.port}",
                    ),
                ).geocode(addressMarker)
            }

            assertSafeEvent(
                events,
                "Geocoding request failed",
                SensitiveMarker("provider request address", addressMarker),
                SensitiveMarker("provider API credential", "geocoder-key-marker-$profile"),
                SensitiveMarker("provider payload and exception detail", exceptionMarker),
                SensitiveMarker("provider response header", "provider-header-marker-$profile"),
                SensitiveMarker("provider message ID", "message-id-marker-$profile"),
            )
        } finally {
            server.stop(0)
        }
    }

    @ParameterizedTest(name = "{0} profile")
    @ValueSource(strings = ["default", "dev"])
    fun `failed ingestion does not emit provider exception details`(profile: String) {
        val exceptionMarker = "ingestion-exception-marker-$profile"
        val provider = mock(EventProvider::class.java)
        `when`(provider.source()).thenReturn(EventSource.TIMEPAD)
        doThrow(IllegalStateException(exceptionMarker))
            .`when`(provider)
            .fetch(isNull())
        val runRepository = mock(IngestionRunRepository::class.java)
        doAnswer { invocation -> invocation.arguments[0] }
            .`when`(runRepository)
            .save(any(dev.whysoezzy.meet.domain.entity.IngestionRun::class.java))
        @Suppress("UNCHECKED_CAST")
        val providers = mock(ObjectProvider::class.java) as ObjectProvider<EventProvider>
        val service = IngestionService(
            providers,
            mock(MeetingUpsertService::class.java),
            runRepository,
            mock(MeetingRepository::class.java),
        )

        val events = captureApplicationLogs(profile) {
            service.runProvider(provider)
        }

        assertSafeEvent(
            events,
            "Ingestion provider failed: source=TIMEPAD",
            SensitiveMarker("provider exception detail", exceptionMarker),
        )
    }

    @ParameterizedTest(name = "{0} profile")
    @ValueSource(strings = ["default", "dev"])
    fun `SMTP provider failures do not emit payload headers message IDs or exception details`(profile: String) {
        val markers = listOf(
            SensitiveMarker("SMTP recipient", "smtp-recipient-$profile@example.com"),
            SensitiveMarker("SMTP payload", "654321"),
            SensitiveMarker("SMTP provider header", "smtp-header-marker-$profile"),
            SensitiveMarker("SMTP provider message ID", "smtp-message-id-marker-$profile"),
            SensitiveMarker("SMTP provider exception detail", "smtp-exception-marker-$profile"),
        )
        val providerFailure = MailSendException(
            "${markers[2].value}:${markers[3].value}:${markers[4].value}",
            SocketTimeoutException(markers[4].value),
        )
        val settings = SmtpRuntimeSettings.from(
            EmailProperties(
                provider = EmailProvider.SMTP,
                fromAddress = "no-reply@example.com",
            ),
            MockEnvironment()
                .withProperty("spring.mail.host", "smtp.example.com")
                .withProperty("spring.mail.username", "smtp-user")
                .withProperty("spring.mail.password", "smtp-password"),
        )

        val events = captureApplicationLogs(profile) {
            assertFailsWith<dev.whysoezzy.meet.service.email.EmailOtpDeliveryException> {
                SmtpEmailOtpSender(ThrowingMailSender(providerFailure), settings).send(
                    EmailOtpMessage(
                        recipient = markers[0].value,
                        code = markers[1].value,
                        expirationMinutes = 5,
                    ),
                )
            }
        }

        assertNoSensitiveMarkers(events, *markers.toTypedArray())
    }

    @ParameterizedTest(name = "{0} profile")
    @ValueSource(strings = ["default", "dev"])
    fun `storage delete failure does not emit supplied path details`(
        profile: String,
        @TempDir root: Path,
    ) {
        val pathMarker = "delete-path-marker-$profile"
        val exceptionMarker = "delete-exception-marker-$profile"
        val properties = StorageProperties().apply {
            uploadDir = root.toString()
            baseUrl = "https://media.invalid"
        }
        val storage = StorageService(properties)
        storage.init()
        val nonEmptyDirectory = Files.createDirectories(root.resolve("meetings").resolve(pathMarker))
        Files.writeString(nonEmptyDirectory.resolve(exceptionMarker), "non-empty directory must not be deleted")

        val events = captureApplicationLogs(profile) {
            storage.deleteUploaded(
                UploadResult(
                    publicUrl = "${properties.baseUrl}/meetings/$pathMarker",
                    relativePath = "meetings/$pathMarker",
                ),
            )
        }

        assertSafeEvent(
            events,
            "Storage file deletion failed",
            SensitiveMarker("cleanup target", pathMarker),
            SensitiveMarker("cleanup exception detail", exceptionMarker),
        )
    }

    @Test
    fun `startup validation does not emit configured credentials or HMAC key ring material`() {
        val currentMaterial = Base64.getEncoder().encodeToString(ByteArray(32) { 41 })
        val previousMaterial = Base64.getEncoder().encodeToString(ByteArray(32) { 42 })
        val markers = listOf(
            SensitiveMarker("current HMAC key ID", "current-key-marker"),
            SensitiveMarker("current HMAC key material", currentMaterial),
            SensitiveMarker("previous HMAC key ID", "previous-key-marker"),
            SensitiveMarker("previous HMAC key material", previousMaterial),
            SensitiveMarker("JWT signing credential", "jwt-signing-credential-marker-32-bytes"),
            SensitiveMarker("admin API credential", "admin-api-credential-marker"),
            SensitiveMarker("database username", "database-user-marker"),
            SensitiveMarker("database password", "database-password-marker"),
            SensitiveMarker("SMTP username", "smtp-user-marker"),
            SensitiveMarker("SMTP password", "smtp-password-marker"),
        )
        val context = GenericApplicationContext().apply {
            environment.propertySources.addFirst(
                MapPropertySource(
                    "sensitive-test-properties",
                    mapOf(
                        "app.jwt.secret" to markers[4].value,
                        "app.admin.api-key" to markers[5].value,
                        "spring.datasource.url" to "jdbc:postgresql://database-marker/meet",
                        "spring.datasource.username" to markers[6].value,
                        "spring.datasource.password" to markers[7].value,
                        "app.sms.provider" to "disabled",
                        "app.email.provider" to "smtp",
                        "app.email.from-address" to "no-reply@example.com",
                        "spring.mail.host" to "smtp.example.com",
                        "spring.mail.username" to markers[8].value,
                        "spring.mail.password" to markers[9].value,
                        "app.otp.hash.current-key-id" to markers[0].value,
                        "app.otp.hash.current-key-base64" to markers[1].value,
                        "app.otp.hash.previous-key-id" to markers[2].value,
                        "app.otp.hash.previous-key-base64" to markers[3].value,
                        "app.http.client-ip.trusted-proxy-cidrs[0]" to "invalid-cidr-marker",
                    ),
                ),
            )
        }

        try {
            val events = captureApplicationLogs("default") {
                assertFailsWith<IllegalArgumentException> {
                    RuntimeConfigurationInitializer().initialize(context)
                }
            }

            assertNoSensitiveMarkers(events, *markers.toTypedArray())
        } finally {
            context.close()
        }
    }

    @Test
    fun `unexpected exception handling does not emit exception details`() {
        val marker = SensitiveMarker("unexpected exception detail", "unexpected-exception-marker")
        val request = MockHttpServletRequest().apply { requestURI = "/runtime-logging-test" }

        val events = captureApplicationLogs("default") {
            val response = ApiExceptionHandler(ApiErrorResponseWriter(ObjectMapper()))
                .unexpected(IllegalStateException(marker.value), request)
            assertEquals(500, response.statusCode.value())
        }

        assertNoSensitiveMarkers(events, marker)
    }

    @Test
    fun `scheduled cleanup failures do not emit exception details`() {
        val challengeMarker = SensitiveMarker("challenge cleanup exception detail", "challenge-cleanup-marker")
        val attemptMarker = SensitiveMarker("attempt cleanup exception detail", "attempt-cleanup-marker")
        val transactionManager = mock(PlatformTransactionManager::class.java)
        `when`(transactionManager.getTransaction(any(TransactionDefinition::class.java)))
            .thenAnswer { SimpleTransactionStatus() }
        val challengeStore = mock(OtpChallengeStore::class.java)
        val attemptStore = mock(OtpAttemptStore::class.java)
        doThrow(IllegalStateException(challengeMarker.value))
            .`when`(challengeStore)
            .cleanup(anyLong(), anyInt())
        doThrow(IllegalStateException(attemptMarker.value))
            .`when`(attemptStore)
            .cleanup(anyLong(), anyInt())

        val events = captureApplicationLogs("default") {
            OtpChallengeCleanupJob(challengeStore, OtpProperties(), transactionManager).cleanup()
            OtpAttemptCleanupJob(
                attemptStore,
                OtpRateLimitProperties(),
                OtpVerificationProperties(),
                transactionManager,
            ).cleanup()
        }

        assertSafeEvent(events, "OTP challenge cleanup failed", challengeMarker, attemptMarker)
        assertTrue(
            events.any { it.formattedMessage.contains("OTP attempt cleanup failed") },
            "expected safe OTP attempt cleanup failure event",
        )
    }

    @Test
    fun `profile levels used by runtime capture match production and dev configuration`() {
        assertFalse(applicationLogLevel("default") == applicationLogLevel("dev"))
    }

    private fun captureApplicationLogs(profile: String, action: () -> Unit): List<ILoggingEvent> {
        val applicationLogger = LoggerFactory.getLogger("dev.whysoezzy") as Logger
        val rootLogger = LoggerFactory.getLogger(Logger.ROOT_LOGGER_NAME) as Logger
        val originalLevel = applicationLogger.level
        val appender = ListAppender<ILoggingEvent>().apply { start() }

        applicationLogger.level = Level.valueOf(applicationLogLevel(profile))
        rootLogger.addAppender(appender)
        try {
            action()
            return appender.list.toList()
        } finally {
            rootLogger.detachAppender(appender)
            appender.stop()
            applicationLogger.level = originalLevel
        }
    }

    private fun assertSafeEvent(
        events: List<ILoggingEvent>,
        expectedEvent: String,
        vararg forbiddenMarkers: SensitiveMarker,
    ) {
        val output = events.joinToString("\n") { event ->
            "${event.formattedMessage}\n${event.throwableProxy?.let(ThrowableProxyUtil::asString).orEmpty()}"
        }
        assertTrue(output.contains(expectedEvent), "expected safe runtime log event '$expectedEvent'")
        assertNoSensitiveMarkers(output, *forbiddenMarkers)
    }

    private fun assertNoSensitiveMarkers(events: List<ILoggingEvent>, vararg markers: SensitiveMarker) {
        val output = events.joinToString("\n") { event ->
            "${event.formattedMessage}\n${event.throwableProxy?.let(ThrowableProxyUtil::asString).orEmpty()}"
        }
        assertNoSensitiveMarkers(output, *markers)
    }

    private fun assertNoSensitiveMarkers(output: String, vararg markers: SensitiveMarker) {
        markers.forEach { marker ->
            assertFalse(
                output.contains(marker.value),
                "runtime log output exposed sensitive category '${marker.category}'",
            )
        }
    }

    private fun applicationLogLevel(profile: String): String =
        Files.newBufferedReader(
            Path.of("src/main/resources", if (profile == "dev") "application-dev.yml" else "application.yml"),
        ).use { reader ->
            @Suppress("UNCHECKED_CAST")
            val logging = Yaml().load<Map<String, Any>>(reader).getValue("logging") as Map<String, Any>
            @Suppress("UNCHECKED_CAST")
            (logging.getValue("level") as Map<String, String>).getValue("dev.whysoezzy")
        }

    private data class SensitiveMarker(
        val category: String,
        val value: String,
    )

    private class ThrowingMailSender(
        private val failure: RuntimeException,
    ) : JavaMailSenderImpl() {
        override fun send(mimeMessage: MimeMessage): Nothing = throw failure
    }
}
