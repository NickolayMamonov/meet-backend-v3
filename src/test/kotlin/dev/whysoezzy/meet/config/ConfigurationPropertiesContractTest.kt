package dev.whysoezzy.meet.config

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ConfigurationPropertiesContractTest {
    @Test
    fun `configuration contracts expose approved defaults`() {
        assertEquals(
            OtpProperties(5, 5, 24, 1_000, 600_000),
            OtpProperties(),
        )
        assertEquals(
            OtpRateLimitProperties(60, 20, false, 10, 1_000, 600_000),
            OtpRateLimitProperties(),
        )
        assertEquals(
            OtpVerificationProperties(15, 5, 50, 10),
            OtpVerificationProperties(),
        )
        assertEquals(ClientIpProperties(emptyList(), 10), ClientIpProperties())
        OtpHashProperties().also { properties ->
            assertEquals("", properties.currentKeyId)
            assertEquals("", properties.currentKeyBase64)
            assertEquals("", properties.previousKeyId)
            assertEquals("", properties.previousKeyBase64)
            assertEquals("OtpHashProperties(redacted)", properties.toString())
        }
    }

    @Test
    fun `configuration contracts reject values outside approved bounds`() {
        listOf(0L, 16L).forEach { invalid ->
            assertFailsWith<IllegalArgumentException> { OtpProperties(expirationMinutes = invalid) }
        }
        listOf(0L, 1_441L).forEach { invalid ->
            assertFailsWith<IllegalArgumentException> { OtpRateLimitProperties(windowMinutes = invalid) }
            assertFailsWith<IllegalArgumentException> { OtpVerificationProperties(windowMinutes = invalid) }
        }
        assertFailsWith<IllegalArgumentException> {
            OtpVerificationProperties(identifierMaxAttempts = 11)
        }
        assertFailsWith<IllegalArgumentException> { ClientIpProperties(maxForwardedHops = 0) }
    }

    @Test
    fun `OTP expiration accepts the minimum default and maximum contract values`() {
        listOf(1L, 5L, 15L).forEach { expirationMinutes ->
            assertEquals(
                expirationMinutes,
                OtpProperties(expirationMinutes = expirationMinutes).expirationMinutes,
            )
        }
    }

    @Test
    fun `cleanup controls accept their minimum positive bounds`() {
        OtpProperties(
            challengeRetentionHours = 1,
            challengeCleanupBatchSize = 1,
            challengeCleanupDelayMs = 1,
        ).also { properties ->
            assertEquals(1L, properties.challengeRetentionHours)
            assertEquals(1, properties.challengeCleanupBatchSize)
            assertEquals(1L, properties.challengeCleanupDelayMs)
        }
        OtpRateLimitProperties(
            cleanupBatchSize = 1,
            cleanupDelayMs = 1,
        ).also { properties ->
            assertEquals(1, properties.cleanupBatchSize)
            assertEquals(1L, properties.cleanupDelayMs)
        }
        listOf(1L, 1_440L).forEach { windowMinutes ->
            assertEquals(windowMinutes, OtpRateLimitProperties(windowMinutes = windowMinutes).windowMinutes)
            assertEquals(windowMinutes, OtpVerificationProperties(windowMinutes = windowMinutes).windowMinutes)
        }
    }

    @Test
    fun `cleanup controls reject zero`() {
        listOf<() -> Any>(
            { OtpProperties(challengeRetentionHours = 0) },
            { OtpProperties(challengeCleanupBatchSize = 0) },
            { OtpProperties(challengeCleanupDelayMs = 0) },
            { OtpRateLimitProperties(cleanupBatchSize = 0) },
            { OtpRateLimitProperties(cleanupDelayMs = 0) },
        ).forEach { construct ->
            assertFailsWith<IllegalArgumentException> { construct() }
        }
    }
}
