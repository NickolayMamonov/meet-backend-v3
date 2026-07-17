package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.bind.Bindable
import org.springframework.boot.context.properties.bind.Binder
import org.springframework.context.ApplicationContextInitializer
import org.springframework.context.ConfigurableApplicationContext

/**
 * Validates required secret-bearing settings before the application context starts creating infrastructure beans,
 * including the datasource.
 */
class JwtConfigurationInitializer : ApplicationContextInitializer<ConfigurableApplicationContext> {
    override fun initialize(applicationContext: ConfigurableApplicationContext) {
        val environment = applicationContext.environment
        val binder = Binder.get(environment)

        binder.bind("app.jwt", Bindable.of(JwtProperties::class.java)).orElseGet(::JwtProperties)
        binder.bind("app.otp", Bindable.of(OtpProperties::class.java)).orElseGet(::OtpProperties)
        binder.bind("app.otp.rate-limit", Bindable.of(OtpRateLimitProperties::class.java)).orElseGet(::OtpRateLimitProperties)
        val sms = binder.bind("app.sms", Bindable.of(SmsProperties::class.java)).orElseGet(::SmsProperties)

        listOf(
            "spring.datasource.url",
            "spring.datasource.username",
            "spring.datasource.password",
        ).forEach { property ->
            require(!environment.getProperty(property).isNullOrBlank()) {
                "$property must be provided"
            }
        }

        val isDev = environment.activeProfiles.contains("dev")
        require(isDev || sms.provider != SmsProvider.FAKE) {
            "app.sms.provider=fake may only be enabled with the dev profile"
        }
    }
}
