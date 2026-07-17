package dev.whysoezzy.meet.config

import jakarta.validation.constraints.Min
import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.validation.annotation.Validated

@Validated
@ConfigurationProperties(prefix = "app.otp")
data class OtpProperties(
    @field:Min(value = 1, message = "app.otp.expiration-minutes must be positive")
    val expirationMinutes: Long = 5,
    @field:Min(value = 1, message = "app.otp.max-attempts-per-hour must be positive")
    val maxAttemptsPerHour: Long = 5,
)
