package dev.whysoezzy.meet.config

import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

class OtpKeyRingTest {
    @Test
    fun `encapsulates current and previous keys behind HMAC operations`() {
        val current = ByteArray(32) { it.toByte() }
        val previous = ByteArray(32) { (it + 32).toByte() }
        val ring = OtpKeyRing.from(
            OtpHashProperties(
                currentKeyId = "current-v2",
                currentKeyBase64 = current.base64(),
                previousKeyId = "previous-v1",
                previousKeyBase64 = previous.base64(),
            ),
        )

        val input = "framed-input".toByteArray()
        assertEquals(32, ring.signCurrent(input).size)
        assertEquals(32, ring.sign("previous-v1", input)?.size)
        assertNotEquals(
            ring.signCurrent(input).contentToString(),
            ring.sign("previous-v1", input)?.contentToString(),
        )
        assertNull(ring.sign("unknown", input))
        assertEquals("OtpKeyRing(redacted)", ring.toString())
    }

    @Test
    fun `rejects incomplete unsafe short duplicate and noncanonical keys`() {
        val valid = ByteArray(32) { it.toByte() }.base64()

        listOf(
            OtpHashProperties(currentKeyId = "", currentKeyBase64 = valid),
            OtpHashProperties(currentKeyId = "unsafe id", currentKeyBase64 = valid),
            OtpHashProperties(currentKeyId = "current", currentKeyBase64 = "not-base64"),
            OtpHashProperties(currentKeyId = "current", currentKeyBase64 = ByteArray(31).base64()),
            OtpHashProperties(currentKeyId = "current", currentKeyBase64 = valid, previousKeyId = "previous"),
            OtpHashProperties(
                currentKeyId = "same",
                currentKeyBase64 = valid,
                previousKeyId = "same",
                previousKeyBase64 = ByteArray(32) { 1 }.base64(),
            ),
            OtpHashProperties(
                currentKeyId = "current",
                currentKeyBase64 = valid,
                previousKeyId = "previous",
                previousKeyBase64 = valid,
            ),
            OtpHashProperties(currentKeyId = "current", currentKeyBase64 = valid.trimEnd('=')),
        ).forEach { properties ->
            assertFailsWith<IllegalArgumentException> { OtpKeyRing.from(properties) }
        }
    }

    private fun ByteArray.base64(): String = Base64.getEncoder().encodeToString(this)
}
