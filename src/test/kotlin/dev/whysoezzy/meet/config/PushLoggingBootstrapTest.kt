package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import org.springframework.boot.context.logging.LoggingApplicationListener
import org.springframework.boot.context.event.ApplicationEnvironmentPreparedEvent
import org.springframework.boot.support.EnvironmentPostProcessorApplicationListener
import org.springframework.boot.WebApplicationType
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.context.ConfigurableApplicationContext
import org.springframework.mock.env.MockEnvironment
import java.nio.charset.StandardCharsets
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith
import java.util.concurrent.atomic.AtomicInteger

class PushLoggingBootstrapTest {
    @Test
    fun `spring factories registers the logging listener and keeps it before logging binding`() {
        val resource = requireNotNull(javaClass.classLoader.getResourceAsStream("META-INF/spring.factories"))
            .use { it.readBytes().toString(StandardCharsets.UTF_8) }
        assertTrue(resource.contains("org.springframework.context.ApplicationListener"))
        assertTrue(resource.contains(PushLoggingEnvironmentListener::class.qualifiedName!!))

        val listener = PushLoggingEnvironmentListener()
        assertTrue(EnvironmentPostProcessorApplicationListener.DEFAULT_ORDER < listener.getOrder())
        assertTrue(listener.getOrder() < LoggingApplicationListener.DEFAULT_ORDER)
    }

    @Test
    fun `bootstrap listener rejects unsafe SDK logger levels before application startup`() {
        val listener = PushLoggingEnvironmentListener()
        val environment = MockEnvironment()
            .withProperty("logging.level.com.google.firebase", "DEBUG")
        val event = ApplicationEnvironmentPreparedEvent(
            org.mockito.Mockito.mock(org.springframework.boot.bootstrap.ConfigurableBootstrapContext::class.java),
            org.springframework.boot.SpringApplication(),
            emptyArray<String>(),
            environment,
        )

        assertFailsWith<IllegalStateException> { listener.onApplicationEvent(event) }
    }

    @Test
    fun `real SpringApplication bootstrap rejects unsafe CLI logging before context entry`() {
        val providerTouches = AtomicInteger()
        val failure = assertFailsWith<IllegalStateException> {
            org.springframework.boot.SpringApplication(BootstrapSource::class.java).apply {
                setWebApplicationType(WebApplicationType.NONE)
            }.run(
                "--spring.main.banner-mode=off",
                "--logging.level.com.google.firebase=DEBUG",
            )
        }

        assertTrue(failure.message.orEmpty().contains(PushRuntimeSettings.INVALID_CONFIGURATION))
        assertTrue(providerTouches.get() == 0)
    }

    @Test
    fun `real SpringApplication bootstrap accepts explicit protected OFF and enters context`() {
        var context: ConfigurableApplicationContext? = null
        try {
            context = org.springframework.boot.SpringApplication(BootstrapSource::class.java).apply {
                setWebApplicationType(WebApplicationType.NONE)
            }.run(
                "--spring.main.banner-mode=off",
                "--logging.level.com.google.firebase=OFF",
                "--logging.level.org.apache.hc.client5.http2.frame=OFF",
            )
            assertTrue(context.isActive)
        } finally {
            context?.close()
        }
    }

    @Configuration(proxyBeanMethods = false)
    private class BootstrapSource
}
