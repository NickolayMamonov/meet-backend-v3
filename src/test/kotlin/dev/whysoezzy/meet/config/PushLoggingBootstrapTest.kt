package dev.whysoezzy.meet.config

import ch.qos.logback.classic.spi.ILoggingEvent
import ch.qos.logback.core.read.ListAppender
import ch.qos.logback.classic.LoggerContext
import com.google.auth.oauth2.ServiceAccountCredentials
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.FirebaseOptions
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.parallel.ResourceLock
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import org.mockito.Mockito.mock
import org.mockito.Mockito.mockStatic
import org.mockito.Mockito.any
import org.mockito.Mockito.anyString
import org.mockito.Mockito.doReturn
import org.slf4j.LoggerFactory
import org.springframework.boot.WebApplicationType
import org.springframework.boot.context.event.ApplicationEnvironmentPreparedEvent
import org.springframework.boot.context.logging.LoggingApplicationListener
import org.springframework.boot.support.EnvironmentPostProcessorApplicationListener
import org.springframework.boot.SpringApplication
import org.springframework.context.ApplicationContextInitializer
import org.springframework.context.ApplicationListener
import org.springframework.context.ConfigurableApplicationContext
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.context.annotation.Import
import org.springframework.core.Ordered
import org.springframework.core.env.ConfigurableEnvironment
import org.springframework.mock.env.MockEnvironment
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.PrintStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicInteger
import java.util.stream.Stream
import java.util.logging.Handler
import java.util.logging.LogManager
import java.util.logging.LogRecord
import java.util.logging.Logger as JulLogger
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@ResourceLock("global-logging-state")
class PushLoggingBootstrapTest {
    @Test
    fun `production spring factories discovery and independent listener ordering are proven`() {
        val resource = requireNotNull(javaClass.classLoader.getResourceAsStream("META-INF/spring.factories"))
            .use { it.readBytes().toString(StandardCharsets.UTF_8) }
        assertTrue(resource.contains("org.springframework.context.ApplicationListener"))
        assertTrue(resource.contains(PushLoggingEnvironmentListener::class.qualifiedName!!))

        val listener = PushLoggingEnvironmentListener()
        assertTrue(EnvironmentPostProcessorApplicationListener.DEFAULT_ORDER < listener.getOrder())
        assertTrue(listener.getOrder() < LoggingApplicationListener.DEFAULT_ORDER)
        assertEquals(LoggingApplicationListener.DEFAULT_ORDER - 1, listener.getOrder())
    }

    @Test
    fun `direct production listener rejects unsafe values without retaining the input`() {
        val marker = "bootstrap-direct-secret-marker"
        val event = ApplicationEnvironmentPreparedEvent(
            mock(org.springframework.boot.bootstrap.ConfigurableBootstrapContext::class.java),
            SpringApplication(),
            emptyArray<String>(),
            MockEnvironment().withProperty("logging.level.com.google.firebase", marker),
        )

        val failure = assertFailsWith<IllegalStateException> {
            PushLoggingEnvironmentListener().onApplicationEvent(event)
        }
        assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, failure.message)
        assertFalse(failure.stackTraceToString().contains(marker))
        assertFalse(failure.suppressed.any { it.stackTraceToString().contains(marker) })
    }

    @ParameterizedTest(name = "{0}={1}, provider-enabled={2}")
    @MethodSource("unsafeLoggingMatrix")
    fun `real bootstrap rejects every prohibited protected override before provider touch`(
        loggerName: String,
        level: String,
        providerEnabled: Boolean,
    ) {
        val marker = "bootstrap-matrix-secret-${loggerName.replace('.', '_')}-${level.lowercase()}-$providerEnabled"
        val result = runApplication(
            arguments = arrayOf(
                "--spring.main.banner-mode=off",
                "--app.push.provider-enabled=$providerEnabled",
                "--app.push.credentials-file=synthetic-local-credential.json",
                "--logging.level.dev.whysoezzy=$marker",
                "--logging.level.$loggerName=$level",
            ),
        )

        assertNotNull(result.failure)
        assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, rootMessage(result.failure!!))
        assertEquals(0, result.providerTouches)
        assertEquals(0, result.downstreamEvents)
        assertEquals(0, result.initializerEntries)
        assertSafeBootstrapOutput(result, marker)
    }

    @Test
    fun `real bootstrap rejects unsafe CLI logging before downstream listener and initializer`() {
        val downstreamEvents = AtomicInteger()
        val initializerEntries = AtomicInteger()
        val marker = "bootstrap-cli-secret-marker"

        val result = runApplication(
            downstreamEvents = downstreamEvents,
            initializerEntries = initializerEntries,
            arguments = arrayOf(
                "--spring.main.banner-mode=off",
                "--logging.level.com.google.firebase=$marker",
            ),
        )

        assertNotNull(result.failure)
        assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, rootMessage(result.failure!!))
        assertEquals(0, result.providerTouches)
        assertEquals(0, downstreamEvents.get())
        assertEquals(0, initializerEntries.get())
        assertSafeBootstrapOutput(result, marker)
    }

    @Test
    fun `real bootstrap sees ConfigData profile values and CLI OFF takes precedence`(@TempDir directory: Path) {
        writeProfile(
            directory,
            """
            logging:
              level:
                "[com.google.firebase]": DEBUG
            """.trimIndent(),
        )
        val profileOnly = runApplication(
            arguments = arrayOf(
                "--spring.main.banner-mode=off",
                "--spring.profiles.active=push-log-test",
                "--spring.config.location=${directory.toUri()}",
            ),
        )
        assertNotNull(profileOnly.failure)
        assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, rootMessage(profileOnly.failure!!))
        assertSafeBootstrapOutput(profileOnly)

        val cliWins = runApplication(
            arguments = arrayOf(
                "--spring.main.banner-mode=off",
                "--spring.profiles.active=push-log-test",
                "--spring.config.location=${directory.toUri()}",
                "--logging.level.[com.google.firebase]=OFF",
            ),
        )
        assertTrue(cliWins.failure == null)
        assertTrue(cliWins.downstreamEvents > 0)
        assertTrue(cliWins.initializerEntries > 0)
        assertEquals(0, cliWins.providerTouches)
    }

    @Test
    fun `profile logging group targeting a bracketed protected descendant is rejected`() {
        val directory = Files.createTempDirectory("push-log-profile")
        try {
            writeProfile(
                directory,
                """
                logging:
                  level:
                    pushProtected: DEBUG
                  group:
                    pushProtected:
                      - "com.google.firebase.synthetic.child"
                """.trimIndent(),
            )
            val result = runApplication(
                arguments = arrayOf(
                    "--spring.main.banner-mode=off",
                    "--spring.profiles.active=push-log-test",
                    "--spring.config.location=${directory.toUri()}",
                ),
            )
            assertNotNull(result.failure)
            assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, rootMessage(result.failure!!))
            assertSafeBootstrapOutput(result)
        } finally {
            Files.walk(directory).sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
        }
    }

    @Test
    fun `safe controls enter the context after logging binding and remain credential free`() {
        val downstreamEvents = AtomicInteger()
        val initializerEntries = AtomicInteger()
        val result = runApplication(
            emitSafeControl = true,
            downstreamEvents = downstreamEvents,
            initializerEntries = initializerEntries,
            arguments = arrayOf(
                "--spring.main.banner-mode=off",
                "--logging.level.com.google.firebase=OFF",
                "--logging.level.org.apache.hc.client5.http2.frame=OFF",
                "--logging.level.dev.whysoezzy=DEBUG",
            ),
        )

        assertTrue(result.failure == null)
        assertTrue(result.contextActive)
        assertTrue(downstreamEvents.get() > 0)
        assertTrue(initializerEntries.get() > 0)
        assertEquals(0, result.providerTouches)
        assertTrue(result.applicationEvents.any { it.formattedMessage.contains("bootstrap-safe-control-event") })
        listOf(
            "com.google.firebase",
            "org.apache.hc.client5.http2.frame",
        ).forEach { name ->
            assertEquals("OFF", result.effectiveLevels[name], name)
        }
    }

    @Test
    fun `provider enabled bootstrap reaches the real factory with synthetic local credentials`(
        @TempDir directory: Path,
    ) {
        val credentials = directory.resolve("synthetic-credentials.json")
        Files.writeString(credentials, "{}")

        val result = runApplication(
            arguments = arrayOf(
                "--spring.main.banner-mode=off",
                "--app.push.provider-enabled=true",
                "--app.push.credentials-file=$credentials",
                "--app.push.project-id=meeting-1d258",
            ),
        )

        assertNull(result.failure)
        assertTrue(result.contextActive)
        assertTrue(result.credentialTouches > 0)
        assertTrue(result.firebaseAppTouches > 0)
        assertTrue(result.providerTouches > 0)
    }

    private fun runApplication(
        emitSafeControl: Boolean = false,
        downstreamEvents: AtomicInteger = AtomicInteger(),
        initializerEntries: AtomicInteger = AtomicInteger(),
        arguments: Array<String>,
    ): BootstrapResult {
        credentialTouchCounter.set(0)
        firebaseAppTouchCounter.set(0)
        providerTouchCounter.set(0)
        val downstream = object : ApplicationListener<ApplicationEnvironmentPreparedEvent>, Ordered {
            override fun onApplicationEvent(event: ApplicationEnvironmentPreparedEvent) {
                downstreamEvents.incrementAndGet()
            }

            override fun getOrder(): Int = LoggingApplicationListener.DEFAULT_ORDER + 1
        }
        val initializer = ApplicationContextInitializer<ConfigurableApplicationContext> {
            initializerEntries.incrementAndGet()
        }
        val application = SpringApplication(BootstrapSource::class.java).apply {
            setWebApplicationType(WebApplicationType.NONE)
            addListeners(downstream)
            addInitializers(initializer, RuntimeConfigurationInitializer())
            setDefaultProperties(validBootstrapProperties())
        }

        val stdout = ByteArrayOutputStream()
        val stderr = ByteArrayOutputStream()
        val previousOut = System.out
        val previousErr = System.err
        val applicationLogger = LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME)
            as ch.qos.logback.classic.Logger
        val safeControlLogger = LoggerFactory.getLogger("dev.whysoezzy.bootstrap")
            as ch.qos.logback.classic.Logger
        val loggerContext = LoggerFactory.getILoggerFactory() as LoggerContext
        val originalLoggerLevels = loggerContext.loggerList.associateWith { it.level }
        val originalJulLevels = LogManager.getLogManager().loggerNames.asSequence()
            .map(JulLogger::getLogger)
            .associateWith { it.level }
        val applicationEvents = ListAppender<ILoggingEvent>().apply { start() }
        applicationLogger.addAppender(applicationEvents)
        val julEvents = mutableListOf<LogRecord>()
        val julHandler = RecordingHandler(julEvents)
        val julLoggers = LogManager.getLogManager().loggerNames.asSequence()
            .map(JulLogger::getLogger)
            .filter { logger ->
                listOf(
                    "com.google.auth",
                    "com.google.api.client",
                    "com.google.firebase",
                    "com.google.auth.http.HttpCredentialsAdapter",
                ).any { logger.name == it || logger.name.startsWith("$it.") }
            }
            .toList()
        julLoggers.forEach { it.addHandler(julHandler) }
        var context: ConfigurableApplicationContext? = null
        var failure: Throwable? = null
        val credentials = mock(ServiceAccountCredentials::class.java)
        doReturn("meeting-1d258").`when`(credentials).projectId
        doReturn(credentials).`when`(credentials).createScoped(any<Collection<String>>())
        doReturn(credentials).`when`(credentials).createWithCustomRetryStrategy(false)
        val credentialStatic = mockStatic(ServiceAccountCredentials::class.java)
        val appStatic = mockStatic(FirebaseApp::class.java)
        val messagingStatic = mockStatic(FirebaseMessaging::class.java)
        val app = mock(FirebaseApp::class.java)
        val messaging = mock(FirebaseMessaging::class.java)
        credentialStatic.`when`<ServiceAccountCredentials> {
            ServiceAccountCredentials.fromStream(any(InputStream::class.java))
        }.thenAnswer {
            credentialTouchCounter.incrementAndGet()
            credentials
        }
        appStatic.`when`<FirebaseApp> {
            FirebaseApp.initializeApp(any(FirebaseOptions::class.java), anyString())
        }.thenAnswer {
            firebaseAppTouchCounter.incrementAndGet()
            app
        }
        messagingStatic.`when`<FirebaseMessaging> {
            FirebaseMessaging.getInstance(any(FirebaseApp::class.java))
        }.thenAnswer {
            providerTouchCounter.incrementAndGet()
            messaging
        }
        try {
            System.setOut(PrintStream(stdout, true, StandardCharsets.UTF_8))
            System.setErr(PrintStream(stderr, true, StandardCharsets.UTF_8))
            try {
                context = application.run(*arguments)
                applicationEvents.start()
                applicationLogger.addAppender(applicationEvents)
                safeControlLogger.addAppender(applicationEvents)
                if (emitSafeControl) {
                    safeControlLogger.warn("bootstrap-safe-control-event")
                }
            } catch (throwable: Throwable) {
                failure = throwable
            }
            return BootstrapResult(
                failure = failure,
                stdout = stdout.toString(StandardCharsets.UTF_8),
                stderr = stderr.toString(StandardCharsets.UTF_8),
                applicationEvents = applicationEvents.list.toList(),
                julEvents = julEvents.toList(),
                effectiveLevels = listOf(
                    "com.google.firebase",
                    "org.apache.hc.client5.http2.frame",
                ).associateWith {
                    (LoggerFactory.getLogger(it) as ch.qos.logback.classic.Logger).effectiveLevel.toString()
                },
                contextActive = context?.isActive == true,
                providerTouches = providerTouchCounter.get(),
                credentialTouches = credentialTouchCounter.get(),
                firebaseAppTouches = firebaseAppTouchCounter.get(),
                downstreamEvents = downstreamEvents.get(),
                initializerEntries = initializerEntries.get(),
            )
        } finally {
            context?.close()
            messagingStatic.close()
            appStatic.close()
            credentialStatic.close()
            julLoggers.forEach { it.removeHandler(julHandler) }
            applicationLogger.detachAppender(applicationEvents)
            safeControlLogger.detachAppender(applicationEvents)
            applicationEvents.stop()
            loggerContext.loggerList.forEach { logger ->
                if (logger in originalLoggerLevels) {
                    logger.level = originalLoggerLevels[logger]
                } else if (ProtectedLoggingPolicy.isSdkNamespace(logger.name) ||
                    ProtectedLoggingPolicy.isBindingNamespace(logger.name) ||
                    ProtectedLoggingPolicy.isDriverNamespace(logger.name)
                ) {
                    logger.level = null
                }
            }
            LogManager.getLogManager().loggerNames.asSequence()
                .map(JulLogger::getLogger)
                .forEach { logger ->
                    if (logger in originalJulLevels) {
                        logger.level = originalJulLevels[logger]
                    } else if (protectedJulNames.any { logger.name == it || logger.name.startsWith("$it.") }) {
                        logger.level = null
                    }
                }
            System.setOut(previousOut)
            System.setErr(previousErr)
        }
    }

    private fun validBootstrapProperties(): Map<String, Any> =
        mapOf(
            "spring.main.web-application-type" to "none",
            "app.jwt.secret" to "j".repeat(32),
            "spring.datasource.url" to "jdbc:postgresql://db.invalid/meet",
            "spring.datasource.username" to "synthetic-user",
            "spring.datasource.password" to "synthetic-password",
            "app.sms.provider" to "disabled",
            "app.email.provider" to "smtp",
            "app.email.from-address" to "no-reply@example.com",
            "spring.mail.host" to "smtp.invalid",
            "spring.mail.username" to "synthetic-mail-user",
            "spring.mail.password" to "synthetic-mail-password",
            "app.otp.hash.current-key-id" to "bootstrap-current",
            "app.otp.hash.current-key-base64" to
                java.util.Base64.getEncoder().encodeToString(ByteArray(32) { 91 }),
            "app.push.provider-enabled" to "false",
            "app.push.discovery-enabled" to "false",
            "app.push.dispatch-enabled" to "false",
            "app.push.diagnostic-enabled" to "false",
            "app.push.maintenance-enabled" to "false",
        )

    private fun writeProfile(directory: Path, body: String) {
        Files.writeString(
            directory.resolve("application-push-log-test.yml"),
            """
            spring:
              config:
                activate:
                  on-profile: push-log-test
            """.trimIndent() + "\n" + body + "\n",
        )
    }

    private fun assertSafeBootstrapOutput(result: BootstrapResult, vararg markers: String) {
        val output = result.stdout + "\n" + result.stderr +
            "\n" + result.failure?.let(::exceptionGraph).orEmpty() +
            "\n" + result.applicationEvents.joinToString("\n") { it.formattedMessage } +
            "\n" + result.julEvents.joinToString("\n") { it.message.orEmpty() }
        markers.forEach { marker ->
            assertFalse(output.contains(marker))
        }
        assertFalse(output.contains("PUSH_CONFIG_INVALID") && output.contains("secret"))
    }

    private fun rootMessage(throwable: Throwable): String =
        generateSequence(throwable) { it.cause }.last().message.orEmpty()

    private fun exceptionGraph(throwable: Throwable): String =
        buildString {
            fun appendThrowable(current: Throwable?) {
                if (current == null) return
                append(current::class.java.name).append(':').append(current.message).append('\n')
                current.suppressed.forEach(::appendThrowable)
                appendThrowable(current.cause)
            }
            appendThrowable(throwable)
        }

    private data class BootstrapResult(
        val failure: Throwable?,
        val stdout: String,
        val stderr: String,
        val applicationEvents: List<ILoggingEvent>,
        val julEvents: List<LogRecord>,
        val effectiveLevels: Map<String, String>,
        val contextActive: Boolean,
        val providerTouches: Int,
        val credentialTouches: Int,
        val firebaseAppTouches: Int,
        val downstreamEvents: Int,
        val initializerEntries: Int,
    )

    @Configuration(proxyBeanMethods = false)
    @Import(FirebasePushConfiguration::class)
    private class BootstrapSource {
        @Bean
        fun pushProperties(environment: ConfigurableEnvironment): PushProperties =
            PushProperties(
                providerEnabled = environment.getProperty("app.push.provider-enabled", Boolean::class.java, false),
                discoveryEnabled = environment.getProperty("app.push.discovery-enabled", Boolean::class.java, false),
                dispatchEnabled = environment.getProperty("app.push.dispatch-enabled", Boolean::class.java, false),
                diagnosticEnabled = environment.getProperty("app.push.diagnostic-enabled", Boolean::class.java, false),
                maintenanceEnabled = environment.getProperty("app.push.maintenance-enabled", Boolean::class.java, false),
                projectId = environment.getProperty("app.push.project-id", "meeting-1d258"),
                credentialsFile = environment.getProperty("app.push.credentials-file", ""),
            )

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
        val credentialTouchCounter = AtomicInteger()
        val firebaseAppTouchCounter = AtomicInteger()
        val providerTouchCounter = AtomicInteger()
        val protectedJulNames = listOf(
            "com.google.auth",
            "com.google.api.client",
            "com.google.firebase",
            "com.google.auth.http.HttpCredentialsAdapter",
        )

        @JvmStatic
        fun unsafeLoggingMatrix(): Stream<Arguments> {
            val sdkNames = listOf(
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
                "org.apache.hc.client5.synthetic.secret",
                "org.apache.hc.core5.synthetic.secret",
            )
            val restrictedSqlNames = listOf(
                "org.springframework.jdbc.core.StatementCreatorUtils",
                "org.springframework.jdbc.core.StatementCreatorUtils.synthetic.descendant",
                "org.hibernate.orm.jdbc.bind",
                "org.hibernate.orm.jdbc.bind.synthetic.descendant",
                "org.postgresql",
                "org.postgresql.jdbc",
                "org.postgresql.jdbc.synthetic.descendant",
            )
            return (sdkNames.flatMap { name ->
                listOf("DEBUG", "TRACE", "INFO", "WARN", "ALL").map { level -> name to level }
            } + restrictedSqlNames.flatMap { name ->
                listOf("DEBUG", "TRACE", "ALL").map { level -> name to level }
            }).flatMap { (name, level) ->
                listOf(
                    Arguments.of(name, level, false),
                    Arguments.of(name, level, true),
                )
            }.stream()
        }
    }
}
