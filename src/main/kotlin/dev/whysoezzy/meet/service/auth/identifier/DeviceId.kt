package dev.whysoezzy.meet.service.auth.identifier

import dev.whysoezzy.meet.api.error.BadRequestException
import org.springframework.stereotype.Component

class DeviceId private constructor(
    internal val value: String,
) {
    override fun toString(): String = "DeviceId(redacted)"

    companion object {
        fun parse(raw: String?): DeviceId? {
            if (raw == null) {
                return null
            }
            if (!SAFE_PATTERN.matches(raw)) {
                throw InvalidDeviceIdException()
            }
            return DeviceId(raw)
        }

        private val SAFE_PATTERN = Regex("^[A-Za-z0-9._~-]{16,128}$")
    }
}

class InvalidDeviceIdException :
    IllegalArgumentException("Invalid device identifier")

@Component
class DeviceIdParser {
    fun parse(raw: String?): DeviceId? =
        try {
            DeviceId.parse(raw)
        } catch (_: InvalidDeviceIdException) {
            throw BadRequestException("X-Device-Id must be 16 to 128 safe ASCII characters")
        }
}
