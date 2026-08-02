package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import dev.whysoezzy.meet.config.OtpVerificationProperties
import mu.KotlinLogging
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import kotlin.math.max

private val logger = KotlinLogging.logger {}

@Component
@ConditionalOnProperty(
    prefix = "app.otp.cleanup",
    name = ["enabled"],
    havingValue = "true",
    matchIfMissing = true,
)
class OtpChallengeCleanupJob(
    private val challengeStore: OtpChallengeStore,
    private val properties: OtpProperties,
    transactionManager: PlatformTransactionManager,
) {
    private val transaction = TransactionTemplate(transactionManager)

    @Scheduled(
        fixedDelayString = "\${app.otp.challenge-cleanup-delay-ms:600000}",
        initialDelayString = "\${app.otp.challenge-cleanup-delay-ms:600000}",
    )
    fun cleanup() {
        try {
            val deleted = requireNotNull(
                transaction.execute {
                    challengeStore.cleanup(
                        properties.challengeRetentionHours,
                        properties.challengeCleanupBatchSize,
                    )
                },
            )
            logger.info { "OTP challenge cleanup removed $deleted rows" }
        } catch (_: RuntimeException) {
            logger.warn { "OTP challenge cleanup failed" }
        }
    }
}

@Component
@ConditionalOnProperty(
    prefix = "app.otp.cleanup",
    name = ["enabled"],
    havingValue = "true",
    matchIfMissing = true,
)
class OtpAttemptCleanupJob(
    private val attemptStore: OtpAttemptStore,
    private val rateProperties: OtpRateLimitProperties,
    private val verificationProperties: OtpVerificationProperties,
    transactionManager: PlatformTransactionManager,
) {
    private val transaction = TransactionTemplate(transactionManager)

    @Scheduled(
        fixedDelayString = "\${app.otp.rate-limit.cleanup-delay-ms:600000}",
        initialDelayString = "\${app.otp.rate-limit.cleanup-delay-ms:600000}",
    )
    fun cleanup() {
        try {
            val deleted = requireNotNull(
                transaction.execute {
                    attemptStore.cleanup(
                        max(rateProperties.windowMinutes, verificationProperties.windowMinutes),
                        rateProperties.cleanupBatchSize,
                    )
                },
            )
            logger.info { "OTP attempt cleanup removed $deleted rows" }
        } catch (_: RuntimeException) {
            logger.warn { "OTP attempt cleanup failed" }
        }
    }
}
