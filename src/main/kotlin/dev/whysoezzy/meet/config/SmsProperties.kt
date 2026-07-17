package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.sms")
data class SmsProperties(
    val provider: SmsProvider = SmsProvider.DISABLED,
)

enum class SmsProvider {
    DISABLED,
    FAKE,
}
