package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import org.springframework.boot.context.logging.LoggingApplicationListener
import org.springframework.boot.context.event.ApplicationEnvironmentPreparedEvent
import org.springframework.boot.support.EnvironmentPostProcessorApplicationListener
import org.springframework.mock.env.MockEnvironment
import java.nio.charset.StandardCharsets
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

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
}
