package dev.whysoezzy.meet.service.auth.otp

import dev.whysoezzy.meet.config.OtpHashProperties
import dev.whysoezzy.meet.config.OtpKeyRing
import dev.whysoezzy.meet.service.auth.identifier.AuthChannel
import dev.whysoezzy.meet.service.auth.identifier.AuthIdentifier
import org.junit.jupiter.api.Test
import java.io.ByteArrayOutputStream
import java.time.LocalDateTime
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OtpHasherTest {
    private val current = ByteArray(32) { (it + 1).toByte() }
    private val previous = ByteArray(32) { (it + 65).toByte() }
    private val keyRing = OtpKeyRing.from(
        OtpHashProperties(
            currentKeyId = "current",
            currentKeyBase64 = Base64.getEncoder().encodeToString(current),
            previousKeyId = "previous",
            previousKeyBase64 = Base64.getEncoder().encodeToString(previous),
        ),
    )
    private val hasher = OtpHasher(keyRing)

    @Test
    fun `uses exact framing a fresh salt and current key without exposing code material`() {
        val identifier = AuthIdentifier.email("Person@Example.COM")
        val code = SensitiveOtpCode.validated("001234")
        val first = hasher.hash(identifier, code)
        val second = hasher.hash(identifier, code)

        assertEquals(16, first.salt().size)
        assertEquals(32, first.codeHash().size)
        assertEquals("current", first.keyId)
        assertFalse(first.salt().contentEquals(second.salt()))
        assertContentEquals(expected(current, identifier, first.salt(), code), first.codeHash())
        val mutableHash = first.codeHash()
        mutableHash[0] = (mutableHash[0].toInt() xor 0xff).toByte()
        assertFalse(mutableHash.contentEquals(first.codeHash()))
        assertEquals("OtpHashMaterial(redacted)", first.toString())
        assertEquals("SensitiveOtpCode(redacted)", code.toString())
        assertEquals("OtpKeyRing(redacted)", keyRing.toString())
    }

    @Test
    fun `verifies current and previous key IDs and rejects wrong codes`() {
        val identifier = AuthIdentifier.email("person@example.com")
        val correct = SensitiveOtpCode.validated("123456")
        val salt = ByteArray(16) { it.toByte() }
        val challenge = OtpChallengeSnapshot(
            id = 1,
            channel = AuthChannel.EMAIL,
            identifier = identifier.canonicalValue,
            codeHash = expected(previous, identifier, salt, correct),
            hashSalt = salt,
            hashKeyId = "previous",
            status = OtpChallengeStatus.ACTIVE,
            failedAttempts = 0,
            maxAttempts = 5,
            expiresAt = LocalDateTime.now().plusMinutes(5),
        )

        assertTrue(hasher.matches(challenge, identifier, correct))
        assertFalse(hasher.matches(challenge, identifier, SensitiveOtpCode.validated("654321")))
    }

    private fun expected(
        key: ByteArray,
        identifier: AuthIdentifier,
        salt: ByteArray,
        code: SensitiveOtpCode,
    ): ByteArray {
        val input = ByteArrayOutputStream().apply {
            write("meet-otp-v1".toByteArray())
            write(0)
            write(identifier.channel.name.toByteArray())
            write(0)
            write(identifier.canonicalValue.toByteArray())
            write(0)
            write(salt)
            write(0)
            write(code.value.toByteArray(Charsets.US_ASCII))
        }.toByteArray()
        return Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(input)
        }
    }
}
