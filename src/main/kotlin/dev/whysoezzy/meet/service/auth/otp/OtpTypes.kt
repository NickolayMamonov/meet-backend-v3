package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.api.dto.AuthResponse
import dev.whysoezzy.meet.service.auth.identifier.AuthChannel
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import dev.whysoezzy.meet.service.OtpRequestContext
import java.time.LocalDateTime

class SensitiveOtpCode private constructor(
    internal val value: String,
) {
    override fun toString(): String = "SensitiveOtpCode(redacted)"

    companion object {
        internal fun generated(value: String): SensitiveOtpCode {
            require(SIX_DIGITS.matches(value)) { "OTP code must contain six digits" }
            return SensitiveOtpCode(value)
        }

        fun validated(value: String): SensitiveOtpCode {
            require(SIX_DIGITS.matches(value)) { "OTP code must contain six digits" }
            return SensitiveOtpCode(value)
        }

        private val SIX_DIGITS = Regex("^[0-9]{6}$")
    }
}

enum class OtpChallengeStatus {
    PENDING,
    ACTIVE,
    CONSUMED,
    EXHAUSTED,
    EXPIRED,
    SUPERSEDED,
    DELIVERY_FAILED,
}

class OtpChallengeSnapshot(
    val id: Long,
    val channel: AuthChannel,
    identifier: String,
    codeHash: ByteArray,
    hashSalt: ByteArray,
    internal val hashKeyId: String,
    val status: OtpChallengeStatus,
    val failedAttempts: Int,
    val maxAttempts: Int,
    val expiresAt: LocalDateTime,
) {
    internal val identifier: String = identifier
    private val storedCodeHash = codeHash.copyOf()
    private val storedHashSalt = hashSalt.copyOf()

    internal fun codeHash(): ByteArray = storedCodeHash.copyOf()

    internal fun hashSalt(): ByteArray = storedHashSalt.copyOf()

    override fun toString(): String =
        "OtpChallengeSnapshot(id=$id, channel=$channel, status=$status)"
}

data class PendingChallenge(
    val id: Long,
)

sealed interface ActivationOutcome {
    data object Activated : ActivationOutcome
    data object Superseded : ActivationOutcome
    data object Expired : ActivationOutcome
}

sealed interface OtpRequestOutcome {
    data object Accepted : OtpRequestOutcome
    data object DeliveryUnavailable : OtpRequestOutcome
    data object ActivationUnavailable : OtpRequestOutcome
    data object PersistenceUnavailable : OtpRequestOutcome
}

sealed interface VerificationOutcome {
    data class Authenticated(val response: AuthResponse) : VerificationOutcome
    data object Invalid : VerificationOutcome
}

data class OtpVerificationCommand(
    val identifier: AuthIdentifier,
    val code: SensitiveOtpCode,
    val context: OtpRequestContext,
    val name: String?,
    val surname: String?,
)

internal class OtpHashMaterial(
    codeHash: ByteArray,
    salt: ByteArray,
    val keyId: String,
) {
    private val storedCodeHash = codeHash.copyOf()
    private val storedSalt = salt.copyOf()

    fun codeHash(): ByteArray = storedCodeHash.copyOf()

    fun salt(): ByteArray = storedSalt.copyOf()

    override fun toString(): String = "OtpHashMaterial(redacted)"
}

internal data class AttemptLimit(
    val scope: String,
    val key: String,
    val maxAttempts: Long,
)

class OtpRequestRateLimitExceeded : RuntimeException("OTP request rate limit exceeded")

internal class ActivationCrossedExpiry : RuntimeException("OTP activation crossed expiry")
