package dev.whysoezzy.meet.config

import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class OtpKeyRing private constructor(
    val currentKeyId: String,
    keys: Map<String, ByteArray>,
) {
    private val acceptedKeys = keys.mapValues { (_, value) -> value.copyOf() }

    internal fun signCurrent(input: ByteArray): ByteArray =
        requireNotNull(sign(currentKeyId, input))

    internal fun sign(keyId: String, input: ByteArray): ByteArray? =
        acceptedKeys[keyId]?.let { key ->
            Mac.getInstance("HmacSHA256").run {
                init(SecretKeySpec(key, "HmacSHA256"))
                doFinal(input)
            }
        }

    override fun toString(): String = "OtpKeyRing(redacted)"

    companion object {
        private val SAFE_KEY_ID = Regex("^[A-Za-z0-9._~-]{1,32}$")
        private const val MINIMUM_KEY_BYTES = 32

        fun from(properties: OtpHashProperties): OtpKeyRing {
            require(SAFE_KEY_ID.matches(properties.currentKeyId)) {
                "app.otp.hash current key ID must be configured as safe ASCII"
            }
            val current = decodeStrict(properties.currentKeyBase64, "current")

            val hasPreviousId = properties.previousKeyId.isNotBlank()
            val hasPreviousMaterial = properties.previousKeyBase64.isNotBlank()
            require(hasPreviousId == hasPreviousMaterial) {
                "app.otp.hash previous key ID and material must be configured together"
            }

            val keys = linkedMapOf(properties.currentKeyId to current)
            if (hasPreviousId) {
                require(SAFE_KEY_ID.matches(properties.previousKeyId)) {
                    "app.otp.hash previous key ID must be safe ASCII"
                }
                require(properties.previousKeyId != properties.currentKeyId) {
                    "app.otp.hash current and previous key IDs must differ"
                }
                val previous = decodeStrict(properties.previousKeyBase64, "previous")
                require(!MessageDigest.isEqual(current, previous)) {
                    "app.otp.hash current and previous key material must differ"
                }
                keys[properties.previousKeyId] = previous
            }
            return OtpKeyRing(properties.currentKeyId, keys)
        }

        private fun decodeStrict(encoded: String, slot: String): ByteArray {
            require(encoded.isNotBlank()) { "app.otp.hash $slot key material must be configured" }
            val decoded = try {
                Base64.getDecoder().decode(encoded)
            } catch (_: IllegalArgumentException) {
                throw IllegalArgumentException("app.otp.hash $slot key material must be strict Base64")
            }
            require(Base64.getEncoder().encodeToString(decoded) == encoded) {
                "app.otp.hash $slot key material must be canonical strict Base64"
            }
            require(decoded.size >= MINIMUM_KEY_BYTES) {
                "app.otp.hash $slot key material must decode to at least $MINIMUM_KEY_BYTES bytes"
            }
            return decoded
        }
    }
}
