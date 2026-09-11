package dev.whysoezzy.meet.config

import ch.qos.logback.classic.Level
import ch.qos.logback.classic.Logger as LogbackLogger
import org.slf4j.LoggerFactory
import org.springframework.core.env.ConfigurableEnvironment
import java.util.logging.Level as JulLevel
import java.util.logging.LogManager
import java.util.logging.Logger as JulLogger

/**
 * Installs the last line of defence before Google credentials or the Firebase SDK
 * are touched. Configuration validation happens first so an explicit unsafe child
 * logger cannot be silently hidden by a parent OFF level.
 */
class GoogleSdkLogGuard private constructor(
    private val retainedJulLoggers: List<JulLogger>,
) {
    fun verifyEffectiveLevels() {
        try {
            val loggerFactory = LoggerFactory.getILoggerFactory()
            if (loggerFactory is ch.qos.logback.classic.LoggerContext) {
                loggerFactory.loggerList.forEach { logger ->
                    val name = logger.name
                    if (ProtectedLoggingPolicy.isSdkNamespace(name) && logger.level != null && logger.level != Level.OFF) {
                        throw ProtectedLoggingPolicy.invalidConfiguration()
                    }
                    if (
                        (ProtectedLoggingPolicy.isBindingNamespace(name) ||
                            ProtectedLoggingPolicy.isDriverNamespace(name)) &&
                        logger.level in setOf(Level.DEBUG, Level.TRACE, Level.ALL)
                    ) {
                        throw ProtectedLoggingPolicy.invalidConfiguration()
                    }
                }
            }
            retainedJulLoggers.forEach { logger ->
                logger.level = JulLevel.OFF
            }
            protectedSlf4jNames.forEach { loggerName ->
                val logger = LoggerFactory.getLogger(loggerName)
                if (logger is LogbackLogger) {
                    logger.level = Level.OFF
                }
            }
        } catch (_: IllegalStateException) {
            throw ProtectedLoggingPolicy.invalidConfiguration()
        } catch (_: Throwable) {
            throw ProtectedLoggingPolicy.invalidConfiguration()
        }
    }

    companion object {
        fun install(environment: ConfigurableEnvironment): GoogleSdkLogGuard {
            ProtectedLoggingPolicy.validate(environment)
            return GoogleSdkLogGuard(createProtectedJulLoggers()).also { it.verifyEffectiveLevels() }
        }

        fun install(): GoogleSdkLogGuard =
            GoogleSdkLogGuard(createProtectedJulLoggers()).also { it.verifyEffectiveLevels() }

        private fun createProtectedJulLoggers(): List<JulLogger> {
            val names = buildSet {
                addAll(protectedJulNames)
                LogManager.getLogManager().loggerNames.asSequence()
                    .filter { name -> protectedJulNames.any { name == it || name.startsWith("$it.") } }
                    .forEach(::add)
            }
            val loggers = names.map(JulLogger::getLogger)
            loggers.forEach { logger ->
                if (
                    logger.name !in protectedJulNames &&
                    logger.level != null &&
                    logger.level != JulLevel.OFF
                ) {
                    throw ProtectedLoggingPolicy.invalidConfiguration()
                }
                if (
                    logger.name in protectedJulNames &&
                    logger.level != null &&
                    logger.level != JulLevel.OFF
                ) {
                    throw ProtectedLoggingPolicy.invalidConfiguration()
                }
            }
            return loggers
        }

        private val protectedJulNames = listOf(
            "com.google.auth",
            "com.google.api.client",
            "com.google.firebase",
            "com.google.auth.http.HttpCredentialsAdapter",
        )
        private val protectedSlf4jNames = protectedJulNames + listOf(
            "org.apache.http",
            "org.apache.hc",
        )
    }
}
