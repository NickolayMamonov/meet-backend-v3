package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.bind.Bindable
import org.springframework.boot.context.properties.bind.Binder
import org.springframework.context.ApplicationContextInitializer
import org.springframework.context.ConfigurableApplicationContext

/**
 * Validates JWT settings before the application context starts creating infrastructure beans,
 * including the datasource.
 */
class JwtConfigurationInitializer : ApplicationContextInitializer<ConfigurableApplicationContext> {
    override fun initialize(applicationContext: ConfigurableApplicationContext) {
        Binder.get(applicationContext.environment)
            .bind("app.jwt", Bindable.of(JwtProperties::class.java))
            .orElseGet(::JwtProperties)
    }
}
