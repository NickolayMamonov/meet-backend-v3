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
        binder.bind("app.admin", Bindable.of(AdminProperties::class.java)).orElseGet(::AdminProperties)
        val otp = binder.bind("app.otp", Bindable.of(OtpProperties::class.java)).orElseGet(::OtpProperties)

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
        require(isDev || !otp.fakeSms) {
            "app.otp.fake-sms may only be enabled with the dev profile"
        }
        require(isDev) {
            "OTP delivery is not implemented outside the dev profile"
        }
    }
}
