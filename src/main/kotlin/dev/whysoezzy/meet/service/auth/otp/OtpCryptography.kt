package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.config.OtpKeyRing
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import org.springframework.stereotype.Component
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.SecureRandom

@Component
class OtpCodeGenerator {
    fun generate(): SensitiveOtpCode =
        SensitiveOtpCode.generated(secureRandom.nextInt(1_000_000).toString().padStart(6, '0'))

    private companion object {
        val secureRandom = SecureRandom()
    }
}

@Component
class OtpHasher(
    private val keyRing: OtpKeyRing,
) {
    internal fun hash(identifier: AuthIdentifier, code: SensitiveOtpCode): OtpHashMaterial =
        hash(identifier, code, ByteArray(SALT_BYTES).also(secureRandom::nextBytes))

    internal fun hash(
        identifier: AuthIdentifier,
        code: SensitiveOtpCode,
        salt: ByteArray,
    ): OtpHashMaterial {
        require(salt.size == SALT_BYTES) { "OTP hash salt must contain 16 bytes" }
        val framed = frame(identifier, salt, code)
        return OtpHashMaterial(
            codeHash = keyRing.signCurrent(framed),
            salt = salt,
            keyId = keyRing.currentKeyId,
        )
    }

    fun matches(
        challenge: OtpChallengeSnapshot,
        identifier: AuthIdentifier,
        code: SensitiveOtpCode,
    ): Boolean {
        val candidate = keyRing.sign(
            challenge.hashKeyId,
            frame(identifier, challenge.hashSalt(), code),
        ) ?: return false
        return MessageDigest.isEqual(challenge.codeHash(), candidate)
    }

    private fun frame(
        identifier: AuthIdentifier,
        salt: ByteArray,
        code: SensitiveOtpCode,
    ): ByteArray {
        val framed = ByteArrayOutputStream().apply {
            write(FRAME)
            write(0)
            write(identifier.channel.name.toByteArray(Charsets.UTF_8))
            write(0)
            write(identifier.canonicalValue.toByteArray(Charsets.UTF_8))
            write(0)
            write(salt)
            write(0)
            write(code.value.toByteArray(Charsets.US_ASCII))
        }.toByteArray()
        return framed
    }

    private companion object {
        const val SALT_BYTES = 16
        val FRAME = "meet-otp-v1".toByteArray(Charsets.UTF_8)
        val secureRandom = SecureRandom()
    }
}
