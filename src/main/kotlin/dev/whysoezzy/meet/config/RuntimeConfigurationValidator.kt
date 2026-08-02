package dev.whysoezzy.meet.config

import dev.whysoezzy.meet.service.auth.identifier.TrustedProxySet
import org.springframework.core.env.ConfigurableEnvironment

object RuntimeConfigurationValidator {
    fun validate(
        environment: ConfigurableEnvironment,
        email: EmailProperties,
        otpHash: OtpHashProperties,
        clientIp: ClientIpProperties,
        sms: SmsProperties,
    ) {
        val profiles = environment.activeProfiles.toSet()
        val mode = when (profiles) {
            setOf("dev") -> RuntimeMode.DEV
            setOf("test") -> RuntimeMode.TEST
            else -> RuntimeMode.PRODUCTION
        }

        require(!(profiles.size > 1 && profiles.any { it == "dev" || it == "test" })) {
            "Development or test profiles cannot be combined with other profiles"
        }
        require(mode == RuntimeMode.DEV || sms.provider != SmsProvider.FAKE) {
            "app.sms.provider=fake may only be enabled with exactly the dev profile"
        }
        if (mode == RuntimeMode.PRODUCTION) {
            require(email.provider == EmailProvider.SMTP) {
                "Production email delivery requires the SMTP provider"
            }
        }
        require(mode != RuntimeMode.PRODUCTION || email.provider != EmailProvider.FAKE) {
            "The fake email provider is restricted to non-production profiles"
        }

        OtpKeyRing.from(otpHash)
        if (mode == RuntimeMode.PRODUCTION) {
            require(
                otpHash.currentKeyId != NON_PRODUCTION_DEV_KEY_ID &&
                    otpHash.currentKeyId != NON_PRODUCTION_TEST_KEY_ID &&
                    otpHash.currentKeyBase64 != NON_PRODUCTION_DEV_KEY_BASE64 &&
                    otpHash.currentKeyBase64 != NON_PRODUCTION_TEST_KEY_BASE64 &&
                    otpHash.previousKeyId != NON_PRODUCTION_DEV_KEY_ID &&
                    otpHash.previousKeyId != NON_PRODUCTION_TEST_KEY_ID &&
                    otpHash.previousKeyBase64 != NON_PRODUCTION_DEV_KEY_BASE64 &&
                    otpHash.previousKeyBase64 != NON_PRODUCTION_TEST_KEY_BASE64,
            ) {
                "Documented non-production OTP HMAC keys are not permitted in production"
            }
        }

        try {
            TrustedProxySet.from(clientIp.trustedProxyCidrs)
        } catch (_: IllegalArgumentException) {
            throw IllegalArgumentException("Trusted proxy CIDR configuration is invalid")
        }

        if (email.provider == EmailProvider.SMTP) {
            SmtpRuntimeSettings.from(email, environment)
        }
    }

    const val NON_PRODUCTION_DEV_KEY_ID = "dev-current"
    const val NON_PRODUCTION_DEV_KEY_BASE64 = "ZGV2LW9ubHktb3RwLWhtYWMta2V5LW1hdGVyaWFsLTMyaA=="
    const val NON_PRODUCTION_TEST_KEY_ID = "test-current"
    const val NON_PRODUCTION_TEST_KEY_BASE64 = "dGVzdC1vbmx5LW90cC1obWFjLWtleS1tYXRlcmlhbC0zMg=="

    private enum class RuntimeMode {
        DEV,
        TEST,
        PRODUCTION,
    }
}
