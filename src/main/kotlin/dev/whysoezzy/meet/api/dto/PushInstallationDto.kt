package dev.whysoezzy.meet.api.dto

import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Size
import java.time.Instant
import java.util.UUID

data class PushInstallationRequest(
    @field:NotBlank(message = "FID is required")
    @field:Size(max = 1024, message = "FID is too long")
    val fid: String,
)

data class PushInstallationDto(
    val installationId: UUID,
    val status: String,
    val lastSeenAt: Instant,
)
