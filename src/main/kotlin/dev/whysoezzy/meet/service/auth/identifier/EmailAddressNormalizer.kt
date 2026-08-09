package dev.whysoezzy.meet.service.auth.identifier

import java.net.IDN
import java.text.Normalizer
import java.util.Locale

enum class EmailNormalizationFailure {
    REQUIRED,
    INVALID,
    TOO_LONG,
}

class EmailNormalizationException(
    val failure: EmailNormalizationFailure,
) : IllegalArgumentException("Email normalization failed")

object EmailAddressNormalizer {
    private val localPart = Regex(
        "^[A-Za-z0-9!#\$%&'*+/=?^_`{|}~-]+(?:\\.[A-Za-z0-9!#\$%&'*+/=?^_`{|}~-]+)*$",
    )
    private val domainLabel = Regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")

    fun normalize(raw: String?): String {
        val stripped = raw?.trim()
        if (stripped.isNullOrEmpty()) {
            throw EmailNormalizationException(EmailNormalizationFailure.REQUIRED)
        }

        val normalized = Normalizer.normalize(stripped, Normalizer.Form.NFC)
        val at = normalized.indexOf('@')
        if (at <= 0 || at != normalized.lastIndexOf('@') || at == normalized.lastIndex) {
            invalid()
        }

        val local = normalized.substring(0, at)
        val unicodeDomain = normalized.substring(at + 1)
        if (local.length !in 1..64 || !localPart.matches(local)) {
            invalid()
        }
        if (
            unicodeDomain.startsWith('.') ||
            unicodeDomain.endsWith('.') ||
            unicodeDomain.split('.').any(String::isEmpty)
        ) {
            invalid()
        }

        val asciiDomain = try {
            IDN.toASCII(unicodeDomain, IDN.USE_STD3_ASCII_RULES).lowercase(Locale.ROOT)
        } catch (_: IllegalArgumentException) {
            invalid()
        }
        val labels = asciiDomain.split('.')
        if (
            labels.size < 2 ||
            asciiDomain.length > 253 ||
            labels.any { it.length !in 1..63 || !domainLabel.matches(it) }
        ) {
            invalid()
        }

        val canonical = "${local.lowercase(Locale.ROOT)}@$asciiDomain"
        if (canonical.length > 254) {
            throw EmailNormalizationException(EmailNormalizationFailure.TOO_LONG)
        }
        return canonical
    }

    private fun invalid(): Nothing =
        throw EmailNormalizationException(EmailNormalizationFailure.INVALID)
}
