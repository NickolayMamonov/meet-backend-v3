package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.email")
data class EmailProperties(
    val provider: EmailProvider = EmailProvider.DISABLED,
    val fromAddress: String = "",
    val fromName: String = "Meet",
    val connectTimeoutMs: Int = 5_000,
    val readTimeoutMs: Int = 5_000,
    val writeTimeoutMs: Int = 5_000,
)

enum class EmailProvider {
    DISABLED,
    FAKE,
    SMTP,
}
