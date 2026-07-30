package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import dev.whysoezzy.meet.config.OtpVerificationProperties
import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import org.springframework.stereotype.Component
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.support.TransactionTemplate

@Component
class OtpRequestRateLimiter(
    private val attemptStore: OtpAttemptStore,
    private val otpProperties: OtpProperties,
    private val rateLimitProperties: OtpRateLimitProperties,
    transactionManager: PlatformTransactionManager,
) {
    private val transaction = TransactionTemplate(transactionManager).apply {
        propagationBehavior = TransactionDefinition.PROPAGATION_REQUIRES_NEW
    }

    fun claim(identifier: AuthIdentifier, context: OtpRequestContext) {
        transaction.executeWithoutResult {
            val limits = buildList {
                add(
                    attemptStore.requestIdentifier(identifier, otpProperties.maxAttemptsPerHour),
                )
                context.clientIp?.let {
                    add(attemptStore.requestIp(it, rateLimitProperties.ipMaxAttempts))
                }
                if (rateLimitProperties.deviceEnabled) {
                    context.deviceId?.let {
                        add(attemptStore.requestDevice(it, rateLimitProperties.deviceMaxAttempts))
                    }
                }
            }
            attemptStore.lock(limits)
            if (attemptStore.isExhausted(limits, rateLimitProperties.windowMinutes)) {
                throw OtpRequestRateLimitExceeded()
            }
            attemptStore.insert(limits)
        }
    }
}

@Component
class OtpVerificationLimiter(
    private val attemptStore: OtpAttemptStore,
    private val rateLimitProperties: OtpRateLimitProperties,
    private val verificationProperties: OtpVerificationProperties,
) {
    internal fun contextLimits(context: OtpRequestContext): List<AttemptLimit> =
        buildList {
            context.clientIp?.let {
                add(attemptStore.verificationIp(it, verificationProperties.ipMaxAttempts))
            }
            if (rateLimitProperties.deviceEnabled) {
                context.deviceId?.let {
                    add(attemptStore.verificationDevice(it, verificationProperties.deviceMaxAttempts))
                }
            }
        }

    internal fun identifierLimit(identifier: AuthIdentifier): AttemptLimit =
        attemptStore.verificationIdentifier(
            identifier,
            verificationProperties.identifierMaxAttempts.toLong(),
        )

    internal fun lock(limits: Collection<AttemptLimit>) = attemptStore.lock(limits)

    internal fun isExhausted(limits: Collection<AttemptLimit>): Boolean =
        attemptStore.isExhausted(limits, verificationProperties.windowMinutes)

    internal fun record(limits: Collection<AttemptLimit>) = attemptStore.insert(limits)
}
