package dev.whysoezzy.meet.service.auth.identifier

import dev.whysoezzy.meet.api.dto.SendEmailOtpRequest
import dev.whysoezzy.meet.api.dto.VerifyEmailOtpRequest
import dev.whysoezzy.meet.api.error.BadRequestException
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import kotlin.test.assertEquals

class EmailOtpRequestValidatorTest {
    private val validator = EmailOtpRequestValidator(DeviceIdParser())

    @Test
    fun `validates in email device code name surname order`() {
        assertMessage("Email is required") {
            validator.validate(
                VerifyEmailOtpRequest(email = null, code = null, name = "x".repeat(101)),
                "short",
            )
        }
        assertMessage("X-Device-Id must be 16 to 128 safe ASCII characters") {
            validator.validate(
                VerifyEmailOtpRequest(email = "person@example.com", code = null),
                "short",
            )
        }
        assertMessage("OTP code must be a six-digit number") {
            validator.validate(
                VerifyEmailOtpRequest(email = "person@example.com", code = "１２３４５６"),
                "device-id-123456",
            )
        }
        assertMessage("Name must not exceed 100 characters") {
            validator.validate(
                VerifyEmailOtpRequest(
                    email = "person@example.com",
                    code = "123456",
                    name = "x".repeat(101),
                    surname = "y".repeat(101),
                ),
                null,
            )
        }
    }

    @Test
    fun `returns a canonical identifier and redacted typed values`() {
        val command = validator.validate(
            SendEmailOtpRequest("Person@Example.COM"),
            "device-id-123456",
        )

        assertEquals("AuthIdentifier(channel=EMAIL)", command.identifier.toString())
        assertEquals("DeviceId(redacted)", command.deviceId.toString())
    }

    private fun assertMessage(message: String, action: () -> Unit) {
        val exception = assertThrows<BadRequestException>(action)
        assertEquals(message, exception.message)
    }
}
