package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.domain.entity.AuthIdentity
import dev.whysoezzy.meet.domain.entity.AuthIdentityType
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.AuthIdentityRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.service.AuthTokenIssuer
import dev.whysoezzy.meet.service.auth.identifier.AuthChannel
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional

@Component
class OtpVerificationExecutor(
    private val identifierLock: OtpIdentifierLock,
    private val challengeStore: OtpChallengeStore,
    private val limiter: OtpVerificationLimiter,
    private val hasher: OtpHasher,
    private val identityRepository: AuthIdentityRepository,
    private val userRepository: UserRepository,
    private val tokenIssuer: AuthTokenIssuer,
) {
    @Transactional
    fun verify(command: OtpVerificationCommand): VerificationOutcome {
        identifierLock.lock(command.identifier)
        val challenge = challengeStore.lockActive(command.identifier)
        val contextLimits = limiter.contextLimits(command.context)

        if (challenge == null) {
            limiter.lock(contextLimits)
            if (!limiter.isExhausted(contextLimits)) {
                limiter.record(contextLimits)
            }
            return VerificationOutcome.Invalid
        }

        val identifierLimit = limiter.identifierLimit(command.identifier)
        val allLimits = contextLimits + identifierLimit
        limiter.lock(allLimits)

        if (!challengeStore.isActiveAndUnexpired(challenge.id)) {
            challengeStore.expireActiveIfNeeded(challenge.id)
            if (!limiter.isExhausted(contextLimits)) {
                limiter.record(contextLimits)
            }
            return VerificationOutcome.Invalid
        }
        if (limiter.isExhausted(allLimits)) {
            return VerificationOutcome.Invalid
        }

        if (!hasher.matches(challenge, command.identifier, command.code)) {
            if (challengeStore.recordMismatch(challenge.id)) {
                limiter.record(allLimits)
            } else {
                limiter.record(contextLimits)
            }
            return VerificationOutcome.Invalid
        }

        if (!challengeStore.consume(challenge.id)) {
            limiter.record(contextLimits)
            return VerificationOutcome.Invalid
        }

        val identityType = when (command.identifier.channel) {
            AuthChannel.PHONE -> AuthIdentityType.PHONE
            AuthChannel.EMAIL -> AuthIdentityType.EMAIL
        }
        val existingIdentity = identityRepository.findByTypeAndNormalizedIdentifier(
            identityType,
            command.identifier.canonicalValue,
        )
        val isNewUser = existingIdentity == null
        val user = if (existingIdentity == null) {
            val created = userRepository.save(
                User(
                    name = command.name ?: "",
                    surname = command.surname ?: "",
                    phone = command.identifier.canonicalValue.takeIf {
                        command.identifier.channel == AuthChannel.PHONE
                    },
                    email = command.identifier.canonicalValue.takeIf {
                        command.identifier.channel == AuthChannel.EMAIL
                    },
                ),
            )
            identityRepository.save(
                AuthIdentity(
                    user = created,
                    type = identityType,
                    normalizedIdentifier = command.identifier.canonicalValue,
                ),
            )
            created
        } else {
            userRepository.findWithLockById(requireNotNull(existingIdentity.user.id))
                ?: throw IllegalStateException("Authenticated user is unavailable")
        }

        if (user.isDeleted) {
            user.deletedAt = null
            userRepository.save(user)
        }
        return VerificationOutcome.Authenticated(tokenIssuer.issue(user, isNewUser))
    }
}
