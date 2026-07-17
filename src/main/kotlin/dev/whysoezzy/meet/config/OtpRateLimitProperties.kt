package dev.whysoezzy.meet.config

import jakarta.validation.constraints.Min
import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.validation.annotation.Validated

@Validated
@ConfigurationProperties(prefix = "app.otp.rate-limit")
data class OtpRateLimitProperties(
    @field:Min(value = 1, message = "app.otp.rate-limit.window-minutes must be positive")
    val windowMinutes: Long = 60,
    @field:Min(value = 1, message = "app.otp.rate-limit.ip-max-attempts must be positive")
    val ipMaxAttempts: Long = 20,
    val deviceEnabled: Boolean = false,
    @field:Min(value = 1, message = "app.otp.rate-limit.device-max-attempts must be positive")
    val deviceMaxAttempts: Long = 10,
)
