package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import org.springframework.mock.env.MockEnvironment
import java.util.logging.Level
import java.util.logging.Logger
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class GoogleSdkLogGuardTest {
    @Test
    fun `SDK namespace recognition covers Google and HTTP descendants`() {
        assertTrue(ProtectedLoggingPolicy.isSdkNamespace("com.google.auth.oauth2"))
        assertTrue(ProtectedLoggingPolicy.isSdkNamespace("org.apache.hc.client5"))
        assertTrue(ProtectedLoggingPolicy.isBindingNamespace("org.hibernate.orm.jdbc.bind.BasicBinder"))
        assertTrue(ProtectedLoggingPolicy.isDriverNamespace("org.postgresql.jdbc"))
    }

    @Test
    fun `install returns a guard and forces protected JUL descendants to OFF`() {
        val logger = Logger.getLogger("com.google.auth.push.guard-test")
        val original = logger.level
        try {
            logger.level = null
            val guard = GoogleSdkLogGuard.install(MockEnvironment())
            assertNotNull(guard)
            guard.verifyEffectiveLevels()
            assertEquals(Level.OFF, logger.level)
        } finally {
            logger.level = original
        }
    }
}
