package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import org.springframework.boot.support.EnvironmentPostProcessorApplicationListener
import org.springframework.mock.env.MockEnvironment
import java.util.logging.Level
import java.util.logging.Logger
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PushStep2ConfigurationTest {
    @Test
    fun `push runtime defaults are disabled and bounded`() {
        val settings = PushRuntimeSettings.from(PushProperties())

        assertFalse(settings.providerEnabled)
        assertFalse(settings.discoveryEnabled)
        assertFalse(settings.dispatchEnabled)
        assertFalse(settings.diagnosticEnabled)
        assertFalse(settings.maintenanceEnabled)
        assertEquals(60L, PushRuntimeSettings.DISCOVERY_INTERVAL_SECONDS)
        assertEquals(4, PushRuntimeSettings.DISPATCH_WORKERS)
        assertEquals(5_000, PushRuntimeSettings.FCM_READ_TIMEOUT_MS)
    }

    @Test
    fun `worker and diagnostic flags require the provider`() {
        assertFailsWith<IllegalArgumentException> {
            PushRuntimeSettings.from(PushProperties(dispatchEnabled = true))
        }
        assertFailsWith<IllegalArgumentException> {
            PushRuntimeSettings.from(PushProperties(diagnosticEnabled = true))
        }
        assertTrue(
            PushRuntimeSettings.from(PushProperties(maintenanceEnabled = true)).maintenanceEnabled,
        )
    }

    @Test
    fun `protected logging accepts only exact safe levels and resolves groups`() {
        ProtectedLoggingPolicy.validate(
            MockEnvironment().withProperty("logging.level.com.google.auth", "OFF"),
        )
        ProtectedLoggingPolicy.validate(
            MockEnvironment()
                .withProperty("logging.group.google", "com.google.auth,org.apache.hc")
                .withProperty("logging.level.google", "OFF"),
        )
        assertFailsWith<IllegalStateException> {
            ProtectedLoggingPolicy.validate(
                MockEnvironment()
                    .withProperty("logging.group.google[0]", "com.google.auth")
                    .withProperty("logging.level.google", "DEBUG"),
            )
        }

        listOf("DEBUG", " OFF ", "BOGUS").forEach { value ->
            val failure = assertFailsWith<IllegalStateException> {
                ProtectedLoggingPolicy.validate(
                    MockEnvironment().withProperty("logging.level.com.google.auth", value),
                )
            }
            assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, failure.message)
        }
    }

    @Test
    fun `listener is after environment post processors and before logging binding`() {
        val listener = PushLoggingEnvironmentListener()
        val order = listener.getOrder()

        assertTrue(
            EnvironmentPostProcessorApplicationListener.DEFAULT_ORDER < order &&
                order < org.springframework.boot.context.logging.LoggingApplicationListener.DEFAULT_ORDER,
        )
    }

    @Test
    fun `JUL protected descendants cannot override OFF`() {
        val logger = Logger.getLogger("com.google.auth.http.HttpCredentialsAdapter.push-test")
        val originalLevel = logger.level
        try {
            logger.level = Level.FINE
            val failure = assertFailsWith<IllegalStateException> {
                GoogleSdkLogGuard.install(MockEnvironment())
            }
            assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, failure.message)
        } finally {
            logger.level = originalLevel
        }
    }
}
