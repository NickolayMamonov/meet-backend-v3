package dev.whysoezzy.meet.service.sms

import dev.whysoezzy.meet.api.error.ServiceUnavailableException
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.stereotype.Component

@Component
@ConditionalOnProperty(
    prefix = "app.sms",
    name = ["provider"],
    havingValue = "disabled",
    matchIfMissing = true,
)
class UnavailableSmsSender : SmsSender {
    override fun sendOtp(phone: String, code: String): Nothing =
        throw ServiceUnavailableException("SMS delivery is not configured")
}
