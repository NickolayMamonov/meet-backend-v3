package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.bind.Bindable
import org.springframework.boot.context.properties.bind.Binder
import org.springframework.context.ApplicationContextInitializer
import org.springframework.context.ConfigurableApplicationContext
import org.springframework.core.env.ConfigurableEnvironment

class RuntimeConfigurationInitializer : ApplicationContextInitializer<ConfigurableApplicationContext> {
    override fun initialize(applicationContext: ConfigurableApplicationContext) {
        val environment = applicationContext.environment
        val binder = Binder.get(environment)

        binder.bind("app.admin", Bindable.of(AdminProperties::class.java)).orElseGet(::AdminProperties)
        binder.bind("app.jwt", Bindable.of(JwtProperties::class.java)).orElseGet(::JwtProperties)
        binder.bind("app.otp", Bindable.of(OtpProperties::class.java)).orElseGet(::OtpProperties)
        binder.bind("app.otp.rate-limit", Bindable.of(OtpRateLimitProperties::class.java))
            .orElseGet(::OtpRateLimitProperties)
        binder.bind("app.otp.verification", Bindable.of(OtpVerificationProperties::class.java))
            .orElseGet(::OtpVerificationProperties)
        val email = binder.bind("app.email", Bindable.of(EmailProperties::class.java)).orElseGet(::EmailProperties)
        val otpHash = binder.bind("app.otp.hash", Bindable.of(OtpHashProperties::class.java))
            .orElseGet(::OtpHashProperties)
        val clientIp = binder.bind("app.http.client-ip", Bindable.of(ClientIpProperties::class.java))
            .orElseGet(::ClientIpProperties)
        val sms = binder.bind("app.sms", Bindable.of(SmsProperties::class.java)).orElseGet(::SmsProperties)

        requireDatasource(environment)
        RuntimeConfigurationValidator.validate(environment, email, otpHash, clientIp, sms)
    }

    private fun requireDatasource(environment: ConfigurableEnvironment) {
        listOf(
            "spring.datasource.url",
            "spring.datasource.username",
            "spring.datasource.password",
        ).forEach { property ->
            require(!environment.getProperty(property).isNullOrBlank()) {
                "$property must be provided"
            }
        }
    }
}
