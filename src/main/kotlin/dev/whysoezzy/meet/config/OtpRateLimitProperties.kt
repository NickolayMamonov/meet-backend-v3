package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.otp.rate-limit")
data class OtpRateLimitProperties(
    val windowMinutes: Long = 60,
    val ipMaxAttempts: Long = 20,
    val deviceEnabled: Boolean = false,
    val deviceMaxAttempts: Long = 10,
    val cleanupBatchSize: Int = 1_000,
    val cleanupDelayMs: Long = 600_000,
) {
    init {
        require(windowMinutes in 1..1_440) { "app.otp.rate-limit.window-minutes must be between 1 and 1440" }
        require(ipMaxAttempts in 1..10_000) { "app.otp.rate-limit.ip-max-attempts must be between 1 and 10000" }
        require(deviceMaxAttempts in 1..10_000) {
            "app.otp.rate-limit.device-max-attempts must be between 1 and 10000"
        }
        require(cleanupBatchSize > 0) { "app.otp.rate-limit.cleanup-batch-size must be positive" }
        require(cleanupDelayMs > 0) { "app.otp.rate-limit.cleanup-delay-ms must be positive" }
    }
}
