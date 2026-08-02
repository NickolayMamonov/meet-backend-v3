package dev.whysoezzy.meet.service.auth.identifier

import dev.whysoezzy.meet.api.dto.SendEmailOtpRequest
import dev.whysoezzy.meet.api.dto.VerifyEmailOtpRequest
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.service.auth.otp.SensitiveOtpCode
import org.springframework.stereotype.Component

data class EmailOtpSendCommand(
    val identifier: AuthIdentifier,
    val deviceId: DeviceId?,
)

data class EmailOtpVerifyCommand(
    val identifier: AuthIdentifier,
    val code: SensitiveOtpCode,
    val name: String?,
    val surname: String?,
    val deviceId: DeviceId?,
)

@Component
class EmailOtpRequestValidator(
    private val deviceIdParser: DeviceIdParser,
) {
    fun validate(
        request: SendEmailOtpRequest,
        rawDeviceId: String?,
    ): EmailOtpSendCommand {
        val identifier = normalizeEmail(request.email)
        return EmailOtpSendCommand(identifier, deviceIdParser.parse(rawDeviceId))
    }

    fun validate(
        request: VerifyEmailOtpRequest,
        rawDeviceId: String?,
    ): EmailOtpVerifyCommand {
        val identifier = normalizeEmail(request.email)
        val deviceId = deviceIdParser.parse(rawDeviceId)
        val code = request.code
            ?.takeIf { CODE_PATTERN.matches(it) }
            ?.let(SensitiveOtpCode::validated)
            ?: throw BadRequestException("OTP code must be a six-digit number")
        request.name?.takeIf { it.length > 100 }?.let {
            throw BadRequestException("Name must not exceed 100 characters")
        }
        request.surname?.takeIf { it.length > 100 }?.let {
            throw BadRequestException("Surname must not exceed 100 characters")
        }
        return EmailOtpVerifyCommand(identifier, code, request.name, request.surname, deviceId)
    }

    private fun normalizeEmail(raw: String?): AuthIdentifier =
        try {
            AuthIdentifier.email(raw)
        } catch (exception: EmailNormalizationException) {
            throw when (exception.failure) {
                EmailNormalizationFailure.REQUIRED -> BadRequestException("Email is required")
                EmailNormalizationFailure.INVALID -> BadRequestException("Email must be valid")
                EmailNormalizationFailure.TOO_LONG ->
                    BadRequestException("Email must not exceed 254 characters")
            }
        }

    private companion object {
        val CODE_PATTERN = Regex("^[0-9]{6}$")
    }
}
