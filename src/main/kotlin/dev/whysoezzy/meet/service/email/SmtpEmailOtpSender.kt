package dev.whysoezzy.meet.service.email

import dev.whysoezzy.meet.config.SmtpRuntimeSettings
import jakarta.mail.MessagingException
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.mail.MailAuthenticationException
import org.springframework.mail.MailException
import org.springframework.mail.MailSendException
import org.springframework.mail.javamail.JavaMailSender
import org.springframework.mail.javamail.MimeMessageHelper
import org.springframework.beans.factory.annotation.Qualifier
import org.springframework.stereotype.Component
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets

@Component
@ConditionalOnProperty(prefix = "app.email", name = ["provider"], havingValue = "smtp")
class SmtpEmailOtpSender(
    @Qualifier("otpJavaMailSender")
    private val mailSender: JavaMailSender,
    private val settings: SmtpRuntimeSettings,
) : EmailOtpSender {
    override fun send(message: EmailOtpMessage) {
        if (
            !SmtpRuntimeSettings.isSupportedMailbox(message.recipient) ||
            !OTP_CODE.matches(message.code) ||
            message.expirationMinutes !in 1..15
        ) {
            throw EmailOtpDeliveryException(EmailDeliveryFailureReason.INVALID_MESSAGE)
        }

        try {
            val mimeMessage = mailSender.createMimeMessage()
            MimeMessageHelper(mimeMessage, false, StandardCharsets.UTF_8.name()).apply {
                setFrom(settings.internetAddress())
                setTo(message.recipient)
                setSubject(SUBJECT)
                setText(body(message), false)
            }
            mailSender.send(mimeMessage)
        } catch (_: MailAuthenticationException) {
            throw EmailOtpDeliveryException(EmailDeliveryFailureReason.AUTHENTICATION)
        } catch (exception: MailSendException) {
            val reason =
                if (exception.hasCause<SocketTimeoutException>()) {
                    EmailDeliveryFailureReason.TIMEOUT
                } else {
                    EmailDeliveryFailureReason.REJECTED
                }
            throw EmailOtpDeliveryException(reason)
        } catch (_: MailException) {
            throw EmailOtpDeliveryException(EmailDeliveryFailureReason.UNAVAILABLE)
        } catch (_: MessagingException) {
            throw EmailOtpDeliveryException(EmailDeliveryFailureReason.INVALID_MESSAGE)
        } catch (_: IllegalArgumentException) {
            throw EmailOtpDeliveryException(EmailDeliveryFailureReason.INVALID_MESSAGE)
        } catch (_: RuntimeException) {
            throw EmailOtpDeliveryException(EmailDeliveryFailureReason.UNAVAILABLE)
        }
    }

    private fun body(message: EmailOtpMessage): String =
        """
        Your Meet verification code is:

        ${message.code}

        This code expires in ${message.expirationMinutes} minutes.
        If you did not request this code, you can ignore this email.
        """.trimIndent()

    private inline fun <reified T : Throwable> Throwable.hasCause(): Boolean {
        var candidate: Throwable? = this
        while (candidate != null) {
            if (candidate is T) {
                return true
            }
            candidate = candidate.cause
        }
        return false
    }

    private companion object {
        const val SUBJECT = "Your Meet verification code"
        val OTP_CODE = Regex("^[0-9]{6}$")
    }
}
