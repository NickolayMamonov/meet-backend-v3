package dev.whysoezzy.meet.service.email

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component

@Component
@Profile("dev | test")
@ConditionalOnProperty(
    prefix = "app.email",
    name = ["provider"],
    havingValue = "disabled",
    matchIfMissing = true,
)
class UnavailableEmailOtpSender : EmailOtpSender {
    override fun send(message: EmailOtpMessage): Nothing =
        throw EmailOtpDeliveryException(EmailDeliveryFailureReason.UNAVAILABLE)
}
