package dev.whysoezzy.meet.config

import org.springframework.boot.context.event.ApplicationEnvironmentPreparedEvent
import org.springframework.boot.context.logging.LoggingApplicationListener
import org.springframework.boot.support.EnvironmentPostProcessorApplicationListener
import org.springframework.context.ApplicationListener
import org.springframework.core.Ordered

/**
 * Runs after ConfigData and other environment post-processors, but immediately
 * before Spring Boot converts logging levels to enums.
 */
class PushLoggingEnvironmentListener :
    ApplicationListener<ApplicationEnvironmentPreparedEvent>,
    Ordered {
    private val order: Int = LoggingApplicationListener.DEFAULT_ORDER - 1

    init {
        check(
            EnvironmentPostProcessorApplicationListener.DEFAULT_ORDER < order &&
                order < LoggingApplicationListener.DEFAULT_ORDER,
        )
    }

    override fun onApplicationEvent(event: ApplicationEnvironmentPreparedEvent) {
        ProtectedLoggingPolicy.validate(event.environment)
    }

    override fun getOrder(): Int = order
}
