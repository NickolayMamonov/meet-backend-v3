package dev.whysoezzy.meet.service.sms

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component

@Component
@Profile("dev")
@ConditionalOnProperty(prefix = "app.sms", name = ["provider"], havingValue = "fake")
class FakeSmsSender : SmsSender {
    override fun sendOtp(phone: String, code: String) = Unit
}
