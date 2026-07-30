package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.otp")
data class OtpProperties(
    val expirationMinutes: Long = 5,
    val maxAttemptsPerHour: Long = 5,
    val challengeRetentionHours: Long = 24,
    val challengeCleanupBatchSize: Int = 1_000,
    val challengeCleanupDelayMs: Long = 600_000,
) {
    init {
        require(expirationMinutes in 1..15) { "app.otp.expiration-minutes must be between 1 and 15" }
        require(maxAttemptsPerHour in 1..100) { "app.otp.max-attempts-per-hour must be between 1 and 100" }
        require(challengeRetentionHours > 0) { "app.otp.challenge-retention-hours must be positive" }
        require(challengeCleanupBatchSize > 0) { "app.otp.challenge-cleanup-batch-size must be positive" }
        require(challengeCleanupDelayMs > 0) { "app.otp.challenge-cleanup-delay-ms must be positive" }
    }
}
