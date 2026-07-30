package dev.whysoezzy.meet.service.auth.identifier

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.util.Locale
import kotlin.test.assertEquals

class EmailAddressNormalizerTest {
    @Test
    fun `canonicalizes ASCII local parts IDN domains Unicode whitespace and aliases`() {
        assertEquals(
            "person+tag@xn--e1afmkfd.xn--p1ai",
            EmailAddressNormalizer.normalize("\u2003PERSON+tag@пример.рф\u2003"),
        )
        assertEquals(
            "first.last@example.com",
            EmailAddressNormalizer.normalize("First.Last@EXAMPLE.COM"),
        )
    }

    @Test
    fun `is locale independent`() {
        val original = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertEquals("i@example.com", EmailAddressNormalizer.normalize("I@EXAMPLE.COM"))
        } finally {
            Locale.setDefault(original)
        }
    }

    @Test
    fun `distinguishes required invalid and overlong canonical values`() {
        assertFailure(null, EmailNormalizationFailure.REQUIRED)
        assertFailure("   ", EmailNormalizationFailure.REQUIRED)
        listOf(
            "not-an-email",
            "a@@example.com",
            ".a@example.com",
            "a..b@example.com",
            "\"quoted\"@example.com",
            "тест@example.com",
            "a@example",
            "a@.example.com",
            "a@example..com",
            "a@example.com.",
        ).forEach { assertFailure(it, EmailNormalizationFailure.INVALID) }

        val maximumLocal = "a".repeat(64)
        val domain = "${"b".repeat(63)}.${"c".repeat(63)}.${"d".repeat(61)}"
        assertEquals(254, EmailAddressNormalizer.normalize("$maximumLocal@$domain").length)
        assertFailure(
            "$maximumLocal@${"b".repeat(63)}.${"c".repeat(63)}.${"d".repeat(62)}",
            EmailNormalizationFailure.TOO_LONG,
        )
    }

    private fun assertFailure(value: String?, expected: EmailNormalizationFailure) {
        val exception = assertThrows<EmailNormalizationException> {
            EmailAddressNormalizer.normalize(value)
        }
        assertEquals(expected, exception.failure)
    }
}
