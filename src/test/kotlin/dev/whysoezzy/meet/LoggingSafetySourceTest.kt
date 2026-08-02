package dev.whysoezzy.meet

import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertFalse

class LoggingSafetySourceTest {

    @Test
    fun `sensitive request data and exception details are not interpolated into log messages`() {
        val sources = listOf(
            "security/JwtService.kt",
            "security/JwtAuthFilter.kt",
            "ingestion/GeocodingService.kt",
            "ingestion/IngestionService.kt",
            "ingestion/timepad/TimepadProvider.kt",
            "service/StorageService.kt",
            "api/controller/MediaController.kt",
            "api/controller/CommunityController.kt",
            "api/controller/MeetingController.kt",
            "service/CommunityService.kt",
            "service/MeetingService.kt",
            "api/controller/AuthController.kt",
            "service/AuthService.kt",
            "service/AuthTokenIssuer.kt",
            "service/auth/identifier/AuthIdentifier.kt",
            "service/auth/identifier/EmailAddressNormalizer.kt",
            "service/auth/identifier/DeviceId.kt",
            "service/auth/identifier/ClientRequestContextResolver.kt",
            "service/auth/otp/OtpRequestFlow.kt",
            "service/auth/otp/OtpVerificationExecutor.kt",
            "service/auth/otp/OtpCleanupJobs.kt",
            "service/email/SmtpEmailOtpSender.kt",
        ).map(::source)

        val unsafeLogValue = Regex(
            """logger\.(?:trace|debug|info|warn|error)\s*\{[^}\n]*\$\{?(?:query|address|email|recipient|code|deviceId|clientIp|canonicalValue|hashKeyId|token|password|username|publicUrl|filePath|targetPath|rootLocation|value|e\.message|exception\.message)""",
        )
        val exceptionLoggingOverload = Regex(
            """logger\.(?:trace|debug|info|warn|error)\s*\(\s*(?:e|exception)\s*\)""",
        )

        sources.forEach { contents ->
            assertFalse(unsafeLogValue.containsMatchIn(contents), "log message interpolates sensitive input")
            assertFalse(exceptionLoggingOverload.containsMatchIn(contents), "log call includes an exception")
        }
    }

    private fun source(relativePath: String): String =
        Files.readString(Path.of("src/main/kotlin/dev/whysoezzy/meet").resolve(relativePath))
}
