package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpVerificationProperties
import dev.whysoezzy.meet.service.OtpRequestContext
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.email.EmailOtpMessage
import dev.whysoezzy.meet.service.email.EmailOtpSender
import dev.whysoezzy.meet.service.sms.SmsSender
import org.springframework.dao.DataAccessException
import org.springframework.stereotype.Component
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.TransactionException
import org.springframework.transaction.support.TransactionTemplate

@Component
class OtpChallengeLifecycle(
    private val challengeStore: OtpChallengeStore,
    private val identifierLock: OtpIdentifierLock,
    private val otpProperties: OtpProperties,
    private val verificationProperties: OtpVerificationProperties,
    transactionManager: PlatformTransactionManager,
) {
    private val transaction = TransactionTemplate(transactionManager)
    private val independentTransaction = TransactionTemplate(transactionManager).apply {
        propagationBehavior = TransactionDefinition.PROPAGATION_REQUIRES_NEW
    }

    internal fun createPending(
        identifier: AuthIdentifier,
        material: OtpHashMaterial,
    ): PendingChallenge =
        requireNotNull(
            transaction.execute {
                identifierLock.lock(identifier)
                challengeStore.insertPending(
                    identifier = identifier,
                    material = material,
                    expirationMinutes = otpProperties.expirationMinutes,
                    maxAttempts = verificationProperties.identifierMaxAttempts,
                )
            },
        )

    fun markDeliveryFailed(challengeId: Long) {
        independentTransaction.executeWithoutResult {
            challengeStore.markPending(challengeId, OtpChallengeStatus.DELIVERY_FAILED)
        }
    }

    fun activate(challengeId: Long): ActivationOutcome =
        try {
            requireNotNull(
                transaction.execute {
                    val persisted = challengeStore.findById(challengeId)
                        ?: throw IllegalStateException("OTP challenge is unavailable")
                    val identifier = AuthIdentifier.persisted(persisted.channel, persisted.identifier)
                    identifierLock.lock(identifier)
                    val challenge = challengeStore.lockById(challengeId)
                        ?: throw IllegalStateException("OTP challenge is unavailable")

                    when (challenge.status) {
                        OtpChallengeStatus.ACTIVE -> return@execute ActivationOutcome.Activated
                        OtpChallengeStatus.SUPERSEDED -> return@execute ActivationOutcome.Superseded
                        OtpChallengeStatus.EXPIRED -> return@execute ActivationOutcome.Expired
                        OtpChallengeStatus.PENDING -> Unit
                        else -> throw IllegalStateException("OTP challenge cannot be activated")
                    }

                    if (challengeStore.hasNewerRequest(challenge)) {
                        challengeStore.markPending(challenge.id, OtpChallengeStatus.SUPERSEDED)
                        return@execute ActivationOutcome.Superseded
                    }
                    if (!challengeStore.isPendingAndUnexpired(challenge.id)) {
                        challengeStore.markPending(challenge.id, OtpChallengeStatus.EXPIRED)
                        return@execute ActivationOutcome.Expired
                    }

                    challengeStore.supersedeActive(challenge)
                    if (!challengeStore.activatePending(challenge.id)) {
                        throw ActivationCrossedExpiry()
                    }
                    ActivationOutcome.Activated
                },
            )
        } catch (_: ActivationCrossedExpiry) {
            independentTransaction.executeWithoutResult {
                challengeStore.markPending(challengeId, OtpChallengeStatus.EXPIRED)
            }
            ActivationOutcome.Expired
        }
}

@Component
class OtpDeliveryRouter(
    private val smsSender: SmsSender,
    private val emailOtpSender: EmailOtpSender,
) {
    fun send(
        identifier: AuthIdentifier,
        code: SensitiveOtpCode,
        expirationMinutes: Long,
    ) {
        try {
            when (identifier.channel) {
                dev.whysoezzy.meet.service.auth.identifier.AuthChannel.PHONE ->
                    smsSender.sendOtp(identifier.canonicalValue, code.value)
                dev.whysoezzy.meet.service.auth.identifier.AuthChannel.EMAIL ->
                    emailOtpSender.send(
                        EmailOtpMessage(
                            recipient = identifier.canonicalValue,
                            code = code.value,
                            expirationMinutes = expirationMinutes,
                        ),
                    )
            }
        } catch (_: RuntimeException) {
            throw OtpDeliveryFailure()
        }
    }
}

private class OtpDeliveryFailure : RuntimeException("OTP delivery failed")

@Component
class OtpRequestCoordinator(
    private val requestRateLimiter: OtpRequestRateLimiter,
    private val codeGenerator: OtpCodeGenerator,
    private val hasher: OtpHasher,
    private val challengeLifecycle: OtpChallengeLifecycle,
    private val deliveryRouter: OtpDeliveryRouter,
    private val otpProperties: OtpProperties,
) {
    fun request(identifier: AuthIdentifier, context: OtpRequestContext): OtpRequestOutcome {
        requestRateLimiter.claim(identifier, context)
        val code = codeGenerator.generate()
        val material = hasher.hash(identifier, code)
        val pending = try {
            challengeLifecycle.createPending(identifier, material)
        } catch (_: DataAccessException) {
            return OtpRequestOutcome.PersistenceUnavailable
        } catch (_: TransactionException) {
            return OtpRequestOutcome.PersistenceUnavailable
        }

        try {
            deliveryRouter.send(identifier, code, otpProperties.expirationMinutes)
        } catch (_: OtpDeliveryFailure) {
            runCatching { challengeLifecycle.markDeliveryFailed(pending.id) }
            return OtpRequestOutcome.DeliveryUnavailable
        }

        return try {
            when (challengeLifecycle.activate(pending.id)) {
                ActivationOutcome.Activated,
                ActivationOutcome.Superseded,
                -> OtpRequestOutcome.Accepted
                ActivationOutcome.Expired -> OtpRequestOutcome.ActivationUnavailable
            }
        } catch (_: DataAccessException) {
            OtpRequestOutcome.ActivationUnavailable
        } catch (_: TransactionException) {
            OtpRequestOutcome.ActivationUnavailable
        }
    }
}
