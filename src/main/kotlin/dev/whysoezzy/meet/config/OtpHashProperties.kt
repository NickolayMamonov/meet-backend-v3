package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.otp.hash")
data class OtpHashProperties(
    val currentKeyId: String = "",
    val currentKeyBase64: String = "",
    val previousKeyId: String = "",
    val previousKeyBase64: String = "",
) {
    override fun toString(): String = "OtpHashProperties(redacted)"
}
