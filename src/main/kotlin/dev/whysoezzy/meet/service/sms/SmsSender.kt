package dev.whysoezzy.meet.service.sms

interface SmsSender {
    fun sendOtp(phone: String, code: String)
}
