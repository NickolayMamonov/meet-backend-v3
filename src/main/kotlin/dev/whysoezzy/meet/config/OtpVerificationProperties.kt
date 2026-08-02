package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.otp.verification")
data class OtpVerificationProperties(
    val windowMinutes: Long = 15,
    val identifierMaxAttempts: Int = 5,
    val ipMaxAttempts: Long = 50,
    val deviceMaxAttempts: Long = 10,
) {
    init {
        require(windowMinutes in 1..1_440) {
            "app.otp.verification.window-minutes must be between 1 and 1440"
        }
        require(identifierMaxAttempts in 1..10) {
            "app.otp.verification.identifier-max-attempts must be between 1 and 10"
        }
        require(ipMaxAttempts in 1..10_000) {
            "app.otp.verification.ip-max-attempts must be between 1 and 10000"
        }
        require(deviceMaxAttempts in 1..10_000) {
            "app.otp.verification.device-max-attempts must be between 1 and 10000"
        }
    }
}
