package dev.whysoezzy.meet.config

import com.google.api.client.http.HttpHeaders
import com.google.api.client.http.HttpRequest
import com.google.api.client.http.HttpResponse
import com.google.auth.Credentials
import com.google.auth.http.HttpCredentialsAdapter
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.parallel.ResourceLock
import org.springframework.mock.env.MockEnvironment
import org.slf4j.LoggerFactory
import java.io.IOException
import java.util.logging.Handler
import java.util.logging.Level as JulLevel
import java.util.logging.LogRecord
import java.util.logging.LogManager
import java.util.logging.Logger as JulLogger
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`

@ResourceLock("global-logging-state")
class GoogleSdkLogGuardTest {
    @Test
    fun `protected SLF4J transport paths and descendants have effective OFF`() {
        withLogbackState {
            val root = LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME)
                as ch.qos.logback.classic.Logger
            val application = LoggerFactory.getLogger("dev.whysoezzy")
                as ch.qos.logback.classic.Logger
            root.level = ch.qos.logback.classic.Level.DEBUG
            application.level = ch.qos.logback.classic.Level.DEBUG

            val names = protectedSlf4jNames
            names.forEach { name ->
                (LoggerFactory.getLogger(name) as ch.qos.logback.classic.Logger).level = null
                (LoggerFactory.getLogger("$name.synthetic.child") as ch.qos.logback.classic.Logger).level = null
            }

            LogManager.getLogManager().loggerNames.asSequence()
                .map(JulLogger::getLogger)
                .filter { logger -> protectedJulNames.any { logger.name == it || logger.name.startsWith("$it.") } }
                .forEach { it.level = JulLevel.OFF }
            val guard = GoogleSdkLogGuard.install(MockEnvironment())
            assertNotNull(guard)
            names.forEach { name ->
                val rootLogger = LoggerFactory.getLogger(name) as ch.qos.logback.classic.Logger
                val childLogger = LoggerFactory.getLogger("$name.synthetic.child")
                    as ch.qos.logback.classic.Logger
                assertEquals(ch.qos.logback.classic.Level.OFF, rootLogger.effectiveLevel, name)
                assertEquals(ch.qos.logback.classic.Level.OFF, childLogger.effectiveLevel, name)
            }
        }
    }

    @Test
    fun `JDBC bind and PostgreSQL driver DEBUG TRACE and ALL overrides are rejected`() {
        listOf(
            "org.springframework.jdbc.core.StatementCreatorUtils",
            "org.hibernate.orm.jdbc.bind.BasicBinder",
            "org.postgresql.jdbc",
            "org.postgresql.jdbc.synthetic.child",
        ).forEach { name ->
            listOf(
                ch.qos.logback.classic.Level.DEBUG,
                ch.qos.logback.classic.Level.TRACE,
                ch.qos.logback.classic.Level.toLevel("ALL"),
            ).forEach { level ->
                withLogbackState {
                    val logger = LoggerFactory.getLogger(name) as ch.qos.logback.classic.Logger
                    logger.level = level
                    val failure = kotlin.test.assertFailsWith<IllegalStateException> {
                        GoogleSdkLogGuard.install(MockEnvironment())
                    }
                    assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, failure.message)
                }
            }
        }
    }

    @Test
    fun `actual HttpCredentialsAdapter refresh failure is suppressed on its JUL logger`() {
        withJulState(HttpCredentialsAdapter::class.java.name) {
            val logger = JulLogger.getLogger(HttpCredentialsAdapter::class.java.name)
            val records = mutableListOf<LogRecord>()
            val handler = RecordingHandler(records)
            logger.addHandler(handler)
            try {
                GoogleSdkLogGuard.install(MockEnvironment())

                val credentials = mock(Credentials::class.java)
                `when`(credentials.refresh()).thenThrow(IOException("refresh-secret-marker"))
                val adapter = HttpCredentialsAdapter(credentials)
                val responseHeaders = HttpHeaders().apply {
                    setAuthenticate("Bearer error=\"invalid_token\"")
                }
                val request = mock(HttpRequest::class.java)
                val response = mock(HttpResponse::class.java)
                `when`(response.headers).thenReturn(responseHeaders)
                `when`(response.statusCode).thenReturn(401)

                assertFalse(adapter.handleResponse(request, response, false))
                assertTrue(records.isEmpty(), "HttpCredentialsAdapter must not publish refresh failures")
                assertEquals(JulLevel.OFF, logger.level)
            } finally {
                logger.removeHandler(handler)
            }
        }
    }

    @Test
    fun `guard preserves global logger state when the test scope exits`() {
        val root = LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME)
            as ch.qos.logback.classic.Logger
        val originalRoot = root.level
        val jul = JulLogger.getLogger("com.google.auth.state-restoration")
        val originalJul = jul.level
        try {
            root.level = ch.qos.logback.classic.Level.INFO
            withJulState(jul.name) {
                jul.level = JulLevel.OFF
                withLogbackState {
                    root.level = ch.qos.logback.classic.Level.DEBUG
                    GoogleSdkLogGuard.install(MockEnvironment())
                }
            }
            assertEquals(ch.qos.logback.classic.Level.INFO, root.level)
            assertEquals(originalJul, jul.level)
        } finally {
            root.level = originalRoot
            jul.level = originalJul
        }
    }

    private fun withLogbackState(action: () -> Unit) {
        val names = buildSet {
            add(org.slf4j.Logger.ROOT_LOGGER_NAME)
            add("dev.whysoezzy")
            addAll(protectedSlf4jNames)
            addAll(protectedSlf4jNames.map { "$it.synthetic.child" })
            addAll(
                listOf(
                    "org.springframework.jdbc.core.StatementCreatorUtils",
                    "org.hibernate.orm.jdbc.bind.BasicBinder",
                    "org.postgresql",
                    "org.postgresql.jdbc",
                    "org.postgresql.jdbc.synthetic.child",
                ),
            )
        }
        val loggers = names.associateWith {
            LoggerFactory.getLogger(it) as ch.qos.logback.classic.Logger
        }
        val levels = loggers.mapValues { it.value.level }
        val julLoggers = LogManager.getLogManager().loggerNames.asSequence()
            .map(JulLogger::getLogger)
            .filter { logger ->
                protectedJulNames.any { logger.name == it || logger.name.startsWith("$it.") }
            }
            .toList()
        val julLevels = julLoggers.associateWith { it.level }
        try {
            julLoggers.forEach { it.level = JulLevel.OFF }
            action()
        } finally {
            loggers.forEach { (name, logger) ->
                logger.level = levels[name]
            }
            julLoggers.forEach { it.level = julLevels[it] }
            LogManager.getLogManager().loggerNames.asSequence()
                .map(JulLogger::getLogger)
                .filter { logger -> protectedJulNames.any { logger.name == it || logger.name.startsWith("$it.") } }
                .filter { it !in julLevels }
                .forEach { it.level = null }
        }
    }

    private fun withJulState(name: String, action: () -> Unit) {
        val loggers = LogManager.getLogManager().loggerNames.asSequence()
            .map(JulLogger::getLogger)
            .filter { logger -> protectedJulNames.any { logger.name == it || logger.name.startsWith("$it.") } }
            .toList()
            .let { existing ->
                if (existing.any { it.name == name }) existing
                else existing + JulLogger.getLogger(name)
            }
        val levels = loggers.associateWith { it.level }
        val parentHandlers = loggers.associateWith { it.useParentHandlers }
        val target = JulLogger.getLogger(name)
        try {
            loggers.forEach { it.level = JulLevel.OFF }
            target.level = null
            action()
        } finally {
            loggers.forEach {
                it.level = levels[it]
                it.useParentHandlers = parentHandlers[it] == true
            }
        }
    }

    private class RecordingHandler(
        private val records: MutableList<LogRecord>,
    ) : Handler() {
        override fun publish(record: LogRecord) {
            records += record
        }

        override fun flush() = Unit

        override fun close() = Unit
    }

    private companion object {
        val protectedJulNames = listOf(
            "com.google.auth",
            "com.google.api.client",
            "com.google.firebase",
            "com.google.auth.http.HttpCredentialsAdapter",
        )
        val protectedSlf4jNames = listOf(
            "com.google.auth",
            "com.google.api.client",
            "com.google.firebase",
            "com.google.auth.http.HttpCredentialsAdapter",
            "org.apache.http",
            "org.apache.hc",
            "org.apache.hc.client5.http.headers",
            "org.apache.hc.client5.http.wire",
            "org.apache.hc.client5.http2.frame",
            "org.apache.hc.client5.http2.frame.payload",
            "org.apache.hc.client5.http2.flow",
            "org.apache.hc.core5.synthetic.secret",
        )
    }
}
