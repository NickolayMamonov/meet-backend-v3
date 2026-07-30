package dev.whysoezzy.meet.service.auth.identifier

enum class AuthChannel {
    PHONE,
    EMAIL,
}

class AuthIdentifier private constructor(
    val channel: AuthChannel,
    internal val canonicalValue: String,
) {
    override fun toString(): String = "AuthIdentifier(channel=$channel)"

    companion object {
        fun phone(raw: String): AuthIdentifier =
            AuthIdentifier(AuthChannel.PHONE, PhoneNumberNormalizer.normalize(raw))

        fun email(raw: String?): AuthIdentifier =
            AuthIdentifier(AuthChannel.EMAIL, EmailAddressNormalizer.normalize(raw))

        internal fun persisted(channel: AuthChannel, canonicalValue: String): AuthIdentifier =
            AuthIdentifier(channel, canonicalValue)
    }
}

object PhoneNumberNormalizer {
    fun normalize(raw: String): String {
        val digits = raw.filter(Char::isDigit)
        return when {
            digits.startsWith("8") && digits.length == 11 -> "+7${digits.substring(1)}"
            digits.startsWith("7") && digits.length == 11 -> "+$digits"
            digits.length == 10 -> "+7$digits"
            else -> raw
        }
    }
}
