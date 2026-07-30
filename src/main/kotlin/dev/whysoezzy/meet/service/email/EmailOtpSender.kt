package dev.whysoezzy.meet.service.email

interface EmailOtpSender {
    fun send(message: EmailOtpMessage)
}

class EmailOtpMessage(
    val recipient: String,
    val code: String,
    val expirationMinutes: Long,
) {
    override fun toString(): String = "EmailOtpMessage(redacted)"
}

enum class EmailDeliveryFailureReason {
    INVALID_MESSAGE,
    AUTHENTICATION,
    TIMEOUT,
    REJECTED,
    UNAVAILABLE,
}

class EmailOtpDeliveryException(
    val reason: EmailDeliveryFailureReason,
) : RuntimeException("Email OTP delivery failed")
