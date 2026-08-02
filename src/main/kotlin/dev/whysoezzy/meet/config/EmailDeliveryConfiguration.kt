package dev.whysoezzy.meet.config

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.core.env.ConfigurableEnvironment
import org.springframework.mail.javamail.JavaMailSender

@Configuration(proxyBeanMethods = false)
class EmailDeliveryConfiguration {
    @Bean
    fun otpKeyRing(properties: OtpHashProperties): OtpKeyRing = OtpKeyRing.from(properties)

    @Bean
    @ConditionalOnProperty(prefix = "app.email", name = ["provider"], havingValue = "smtp")
    fun smtpRuntimeSettings(
        properties: EmailProperties,
        environment: ConfigurableEnvironment,
    ): SmtpRuntimeSettings = SmtpRuntimeSettings.from(properties, environment)

    @Bean("otpJavaMailSender")
    @ConditionalOnProperty(prefix = "app.email", name = ["provider"], havingValue = "smtp")
    fun otpJavaMailSender(settings: SmtpRuntimeSettings): JavaMailSender = settings.createMailSender()
}
