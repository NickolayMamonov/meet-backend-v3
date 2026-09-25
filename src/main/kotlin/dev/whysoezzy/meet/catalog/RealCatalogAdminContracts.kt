package dev.whysoezzy.meet.catalog

import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.PositiveOrZero

data class RealCatalogPreviewRequest(
    @field:NotBlank
    val revision: String,
    @field:NotBlank
    val digest: String,
    @field:PositiveOrZero
    val expectedGeneration: Long = 0,
)

data class RealCatalogApplyRequest(
    @field:NotBlank
    val revision: String,
    @field:NotBlank
    val digest: String,
    @field:PositiveOrZero
    val expectedGeneration: Long = 0,
    @field:NotBlank
    val contentApprovalRef: String,
    @field:NotBlank
    val mutationAuthorizationRef: String,
    @field:NotBlank
    val recoveryPointRef: String,
)

data class RealCatalogOperationResponse(
    val catalogKey: String,
    val digest: String,
    val generation: Long,
    val changed: Boolean,
    val activeCommunities: Int,
    val activeMeetings: Int,
    val retiredCommunities: Int,
    val retiredMeetings: Int,
    val discoverableUntil: String,
    val changedKeys: List<String>,
    val conflicts: List<String>,
)
