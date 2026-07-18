package dev.whysoezzy.meet

import ch.qos.logback.classic.Level
import ch.qos.logback.classic.Logger
import ch.qos.logback.classic.spi.ILoggingEvent
import ch.qos.logback.core.read.ListAppender
import com.sun.net.httpserver.HttpServer
import org.yaml.snakeyaml.Yaml
import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.JwtProperties
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
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.isNull
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.ObjectProvider
import org.springframework.web.client.RestClient
import java.net.InetSocketAddress
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertContains
import kotlin.test.assertFalse

class RuntimeLoggingSafetyTest {

    @ParameterizedTest(name = "{0} profile")
    @ValueSource(strings = ["default", "dev"])
    fun `invalid JWT is not emitted at either configured application log level`(profile: String) {
        val tokenMarker = "jwt-secret-marker-$profile"
        val events = captureApplicationLogs(profile) {
            JwtService(JwtProperties(secret = "test-jwt-signing-secret-that-is-at-least-32-bytes"))
                .validateToken(tokenMarker)
        }

        assertSafeEvent(events, "JWT validation failed", tokenMarker)
    }

    @ParameterizedTest(name = "{0} profile")
    @ValueSource(strings = ["default", "dev"])
    fun `failed geocoding does not emit supplied address or failure details`(profile: String) {
        val addressMarker = "address-marker-$profile"
        val exceptionMarker = "geocoder-exception-marker-$profile"
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
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

            assertSafeEvent(events, "Geocoding request failed", addressMarker, exceptionMarker)
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

        assertSafeEvent(events, "Ingestion provider failed: source=TIMEPAD", exceptionMarker)
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
            storage.deleteByUrl("${properties.baseUrl}/meetings/$pathMarker")
        }

        assertSafeEvent(events, "Storage file deletion failed", pathMarker, exceptionMarker)
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

    private fun assertSafeEvent(events: List<ILoggingEvent>, expectedEvent: String, vararg forbiddenMarkers: String) {
        val output = events.joinToString("\n") { event ->
            "${event.formattedMessage}\n${event.throwableProxy}"
        }
        assertContains(output, expectedEvent)
        forbiddenMarkers.forEach { marker ->
            assertFalse(output.contains(marker), "runtime log output leaked '$marker': $output")
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
}
