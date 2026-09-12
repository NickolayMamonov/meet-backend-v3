package dev.whysoezzy.meet.config

import com.google.auth.oauth2.ServiceAccountCredentials
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import dev.whysoezzy.meet.service.push.PushProvider
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.parallel.ResourceLock
import org.mockito.Mockito.any
import org.mockito.Mockito.anyString
import org.mockito.Mockito.mock
import org.mockito.Mockito.mockStatic
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.boot.test.context.runner.ApplicationContextRunner
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.context.annotation.Import
import org.springframework.mock.env.MockEnvironment
import org.slf4j.LoggerFactory
import ch.qos.logback.classic.LoggerContext
import java.util.logging.LogManager
import java.util.logging.Level as JulLevel
import java.util.logging.Logger as JulLogger
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@ResourceLock("global-logging-state")
class FirebasePushConfigurationTest {
    @Test
    fun `provider bean is conditional on provider enablement and missing push provider`() {
        val method = FirebasePushConfiguration::class.java.getDeclaredMethod(
            "firebasePushProvider",
            PushProperties::class.java,
            org.springframework.core.env.ConfigurableEnvironment::class.java,
        )
        val property = method.getAnnotation(ConditionalOnProperty::class.java)
        assertEquals("provider-enabled", property.name.single())
        assertEquals("true", property.havingValue)
        assertContentEquals(
            arrayOf(PushProvider::class.java.name),
            method.getAnnotation(ConditionalOnMissingBean::class.java).value.map { it.java.name }.toTypedArray(),
        )
    }

    @Test
    fun `disabled provider context never creates a Firebase app or touches credentials`() {
        val before = FirebaseApp.getApps().map { it.name }.toSet()
        var running = false
        var hasProvider = true
        ApplicationContextRunner()
            .withUserConfiguration(DisabledProviderConfiguration::class.java)
            .withPropertyValues("app.push.provider-enabled=false")
            .run { context ->
                running = context.isRunning
                hasProvider = context.containsBean("firebasePushProvider")
            }

        assertTrue(running)
        assertFalse(hasProvider)
        assertEquals(before, FirebaseApp.getApps().map { it.name }.toSet())
    }

    @Test
    fun `enabled provider uses only a local synthetic credential and creates no network client`(
        @TempDir directory: Path,
    ) {
        val credentials = directory.resolve("synthetic-service-account.json")
        Files.writeString(credentials, syntheticServiceAccountJson())
        val configuration = FirebasePushConfiguration()
        var provider: AutoCloseable? = null
        withSafeLoggingState {
            try {
                provider = configuration.firebasePushProvider(
                    PushProperties(
                        providerEnabled = true,
                        projectId = SYNTHETIC_PROJECT,
                        credentialsFile = credentials.toString(),
                    ),
                    MockEnvironment(),
                )
                assertNotNull(provider)
                val app = FirebaseApp.getApps().firstOrNull { it.name.startsWith("meet-push-") }
                assertNotNull(app, "the enabled path must own a named Firebase app")
                assertEquals(SYNTHETIC_PROJECT, app.options.projectId)
                assertEquals(PushRuntimeSettings.FCM_CONNECT_TIMEOUT_MS, app.options.connectTimeout)
                assertEquals(PushRuntimeSettings.FCM_READ_TIMEOUT_MS, app.options.readTimeout)
                assertEquals(PushRuntimeSettings.FCM_WRITE_TIMEOUT_MS, app.options.writeTimeout)
            } finally {
                provider?.close()
            }
        }
        assertTrue(FirebaseApp.getApps().none { it.name.startsWith("meet-push-") })
    }

    @Test
    fun `unsafe effective transport logging rejects before synthetic credential loading`() {
        val marker = "synthetic-credential-touch-marker"
        val credentials = kotlin.io.path.createTempFile("firebase-push", ".json")
        val credentialTouches = AtomicInteger()
        val appTouches = AtomicInteger()
        val credentialStatic = mockStatic(ServiceAccountCredentials::class.java)
        val appStatic = mockStatic(FirebaseApp::class.java)
        try {
            Files.writeString(credentials, syntheticServiceAccountJson().replace(SYNTHETIC_PROJECT, marker))
            credentialStatic.`when`<ServiceAccountCredentials> {
                ServiceAccountCredentials.fromStream(any(InputStream::class.java))
            }.thenAnswer {
                credentialTouches.incrementAndGet()
                mock(ServiceAccountCredentials::class.java)
            }
            appStatic.`when`<FirebaseApp> {
                FirebaseApp.initializeApp(any(FirebaseOptions::class.java), anyString())
            }.thenAnswer {
                appTouches.incrementAndGet()
                mock(FirebaseApp::class.java)
            }
            val environment = MockEnvironment()
                .withProperty("logging.level.org.apache.hc.client5.http2.frame.payload", "DEBUG")
            val failure = withSafeLoggingState {
                assertFailsWith<IllegalStateException> {
                    FirebasePushConfiguration().firebasePushProvider(
                        PushProperties(
                            providerEnabled = true,
                            projectId = SYNTHETIC_PROJECT,
                            credentialsFile = credentials.toString(),
                        ),
                        environment,
                    )
                }
            }
            assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, failure.message)
            assertFalse(failure.stackTraceToString().contains(marker))
            assertEquals(0, credentialTouches.get())
            assertEquals(0, appTouches.get())
        } finally {
            appStatic.close()
            credentialStatic.close()
            Files.deleteIfExists(credentials)
        }
    }

    @Test
    fun `missing malformed and wrong project credentials are static failures`() {
        withSafeLoggingState {
            val configuration = FirebasePushConfiguration()
            val environment = MockEnvironment()
            val missing = assertFailsWith<IllegalStateException> {
                configuration.firebasePushProvider(
                    PushProperties(providerEnabled = true, credentialsFile = "missing-synthetic.json"),
                    environment,
                )
            }
            assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, missing.message)

            val malformed = kotlin.io.path.createTempFile("push-test", ".json")
            val wrongProject = kotlin.io.path.createTempFile("push-test", ".json")
            try {
                Files.writeString(malformed, "{}")
                val malformedFailure = assertFailsWith<IllegalStateException> {
                    configuration.firebasePushProvider(
                        PushProperties(providerEnabled = true, credentialsFile = malformed.toString()),
                        environment,
                    )
                }
                assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, malformedFailure.message)

                Files.writeString(
                    wrongProject,
                    syntheticServiceAccountJson(project = "another-synthetic-project"),
                )
                val wrongProjectFailure = assertFailsWith<IllegalStateException> {
                    configuration.firebasePushProvider(
                        PushProperties(
                            providerEnabled = true,
                            projectId = SYNTHETIC_PROJECT,
                            credentialsFile = wrongProject.toString(),
                        ),
                        environment,
                    )
                }
                assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, wrongProjectFailure.message)
            } finally {
                Files.deleteIfExists(malformed)
                Files.deleteIfExists(wrongProject)
            }
        }
    }

    private fun <T> withSafeLoggingState(action: () -> T): T {
        val context = LoggerFactory.getILoggerFactory() as LoggerContext
        val loggers = context.loggerList
        val levels = loggers.associateWith { it.level }
        val julLoggers = LogManager.getLogManager().loggerNames.asSequence()
            .map(JulLogger::getLogger)
            .filter { logger ->
                protectedJulNames.any { logger.name == it || logger.name.startsWith("$it.") }
            }
            .toList()
        val julLevels = julLoggers.associateWith { it.level }
        try {
            loggers.forEach { logger ->
                when {
                    ProtectedLoggingPolicy.isSdkNamespace(logger.name) -> logger.level = null
                    ProtectedLoggingPolicy.isBindingNamespace(logger.name) ||
                        ProtectedLoggingPolicy.isDriverNamespace(logger.name) -> logger.level =
                        ch.qos.logback.classic.Level.OFF
                }
            }
            julLoggers.forEach { it.level = JulLevel.OFF }
            return action()
        } finally {
            context.loggerList.forEach { logger ->
                if (logger in levels) {
                    logger.level = levels[logger]
                } else if (ProtectedLoggingPolicy.isSdkNamespace(logger.name)) {
                    logger.level = null
                }
            }
            julLoggers.forEach { it.level = julLevels[it] }
            LogManager.getLogManager().loggerNames.asSequence()
                .map(JulLogger::getLogger)
                .filter { logger -> protectedJulNames.any { logger.name == it || logger.name.startsWith("$it.") } }
                .filter { it !in julLevels }
                .forEach { it.level = null }
        }
    }

    @Configuration(proxyBeanMethods = false)
    @Import(FirebasePushConfiguration::class)
    private class DisabledProviderConfiguration {
        @Bean
        fun pushProperties(): PushProperties = PushProperties()
    }

    private fun syntheticServiceAccountJson(project: String = SYNTHETIC_PROJECT): String =
        """
        {
          "type": "service_account",
          "project_id": "$project",
          "private_key_id": "synthetic-key",
          "private_key": "${PRIVATE_KEY.replace("\n", "\\n")}",
          "client_email": "synthetic@$project.iam.gserviceaccount.com",
          "client_id": "1234567890",
          "auth_uri": "https://accounts.google.com/o/oauth2/auth",
          "token_uri": "https://oauth2.googleapis.com/token",
          "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
          "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/synthetic"
        }
        """.trimIndent()

    private companion object {
        const val SYNTHETIC_PROJECT = "meeting-1d258"
        val protectedJulNames = listOf(
            "com.google.auth",
            "com.google.api.client",
            "com.google.firebase",
            "com.google.auth.http.HttpCredentialsAdapter",
        )
        val PRIVATE_KEY =
            """
            -----BEGIN PRIVATE KEY-----
            MIICeAIBADANBgkqhkiG9w0BAQEFAASCAmIwggJeAgEAAoGBAM/WK1qQzEEiPDET
            AufywrsdgjqgezhTvP9n3cxwmgY2I455sGm7q6fY55vTD3SM7g/lKGBUgTsLqc9i
            0z6gqO7JLzW/JAREXAQjTQqNjhzVPD9zRC/pMzlvpy5ZF0tGdKzwpKnah5jurhAG
            w77JEEbEeA2VnlbKGu957U2KVHoLAgMBAAECgYEAj+qIyMS9e1i+f2jfuUejyjgL
            xpb73Cw4Ek+VCYzrSuPQSUdAfmbC3Y5YCtHiwN0ZuA4BoHrDpeRUqNOQ3awYbUjo
            TteXRImrDnDTRe97Lv6Qty9Vue7WKRC5tewKrIKnf2s60UZnofHwcglnyIIr0dIl
            CfB2282kJvit4qOCgjECQQD2JexsmR18qor7z+HWpGrACQi8QJfIl4/o9M/Hjk85
            dSRTjV2WL6XiLqNuNZ++D6aqBlzrlguhY5vj0euJU+fjAkEA2Cey+zehz96aBpjb
            uz6dTtZLY6wqorQFakW6mtnTD3xh9lC9GXuX/f4BbqjWj3W8OXoLTB67hCXTvJ6n
            3IUtuQJAaTh240lkqHkCpngL00Q/ec2i1U5LU+0uEGguNeDojug7WhgRDHVb1N8Y
            77Cuk4F/PikwKWjfmeLJrc57gB3E/wJBAJLiz16lnGD8nOB0yYTBdPaY6xwtZ7+u
            46sm/TqzYRi55nwSu53wfgXMsT54n21XjXPlen3cuIKBjhQ0IE/bdIkCQQCorSal
            qKRNwGYPfFsQfMVJVoHRqVLcR07O6Lvb5a7E01VZCfW/DQPSTWhT6piuustAR5GJ
            H3JxIbHUpEnWnMlz
            -----END PRIVATE KEY-----
            """.trimIndent()
    }
}
