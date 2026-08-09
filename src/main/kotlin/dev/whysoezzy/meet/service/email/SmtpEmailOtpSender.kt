package dev.whysoezzy.meet.service.email

import dev.whysoezzy.meet.config.SmtpRuntimeSettings
import jakarta.mail.MessagingException
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Qualifier
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.mail.MailAuthenticationException
import org.springframework.mail.MailException
import org.springframework.mail.MailSendException
import org.springframework.mail.javamail.JavaMailSender
import org.springframework.mail.javamail.MimeMessageHelper
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
    private val logger = LoggerFactory.getLogger(SmtpEmailOtpSender::class.java)

    override fun send(message: EmailOtpMessage) {
        if (
            !SmtpRuntimeSettings.isSupportedMailbox(message.recipient) ||
            !OTP_CODE.matches(message.code) ||
            message.expirationMinutes !in 1..15
        ) {
            fail(EmailDeliveryFailureReason.INVALID_MESSAGE)
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
            fail(EmailDeliveryFailureReason.AUTHENTICATION)
        } catch (exception: MailSendException) {
            val reason =
                if (exception.hasCause<SocketTimeoutException>()) {
                    EmailDeliveryFailureReason.TIMEOUT
                } else {
                    EmailDeliveryFailureReason.REJECTED
                }
            fail(reason)
        } catch (_: MailException) {
            fail(EmailDeliveryFailureReason.UNAVAILABLE)
        } catch (_: MessagingException) {
            fail(EmailDeliveryFailureReason.INVALID_MESSAGE)
        } catch (_: IllegalArgumentException) {
            fail(EmailDeliveryFailureReason.INVALID_MESSAGE)
        } catch (_: RuntimeException) {
            fail(EmailDeliveryFailureReason.UNAVAILABLE)
        }
    }

    private fun fail(reason: EmailDeliveryFailureReason): Nothing {
        logger.warn("Email OTP delivery failed provider=smtp operation=send_otp outcome={}", reason)
        throw EmailOtpDeliveryException(reason)
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
