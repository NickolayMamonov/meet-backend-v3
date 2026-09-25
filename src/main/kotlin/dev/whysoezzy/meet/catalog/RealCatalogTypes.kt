package dev.whysoezzy.meet.catalog

import dev.whysoezzy.meet.domain.entity.MeetingStatus
import java.time.Instant

enum class RealCatalogIntent { INITIAL, REVIEW, NEW_WINDOW, CORRECT }

enum class RealCatalogMembership { ACTIVE, RETIRED }

data class RealCatalogManifest(
    val schemaVersion: String,
    val catalogKey: String,
    val revisionLabel: String,
    val intent: RealCatalogIntent,
    val ownerRole: String,
    val invitationAt: Instant,
    val invitationZone: String,
    val windowEndAt: Instant,
    val reviewAt: Instant,
    val nextReviewAt: Instant,
    val predecessorDigest: String?,
    val communities: List<RealCatalogCommunity>,
    val meetings: List<RealCatalogMeeting>,
)

data class RealCatalogCommunity(
    val logicalKey: String,
    val membership: RealCatalogMembership,
    val name: String,
    val description: String,
    val imageUrl: String,
    val tags: List<String>,
    val source: RealCatalogSource,
    val provenance: RealCatalogFieldProvenance,
)

data class RealCatalogMeeting(
    val logicalKey: String,
    val membership: RealCatalogMembership,
    val title: String,
    val description: String,
    val imageUrl: String,
    val startAt: Instant,
    val endAt: Instant?,
    val sourceZone: String,
    val dateLabel: String,
    val address: String,
    val latitude: Double,
    val longitude: Double,
    val capacity: Int,
    val isOnline: Boolean,
    val status: MeetingStatus = MeetingStatus.ACTIVE,
    val tags: List<String>,
    val communityKey: String,
    val externalUrl: String?,
    val source: RealCatalogSource,
    val provenance: RealCatalogFieldProvenance,
)

data class RealCatalogSource(
    val publicUrl: String,
    val checkedAt: Instant,
    val basis: String,
    val evidenceRef: String,
    val attribution: String,
    val retentionPermission: String,
    val discoveryUseCutoff: Instant? = null,
)

data class RealCatalogFieldProvenance(
    val title: RealCatalogSource? = null,
    val description: RealCatalogSource? = null,
    val image: RealCatalogSource? = null,
    val organizer: RealCatalogSource? = null,
    val schedule: RealCatalogSource? = null,
    val location: RealCatalogSource? = null,
)

data class RealCatalogResolvedItem(
    val kind: String,
    val logicalKey: String,
    val entityId: Long?,
    val membership: RealCatalogMembership,
    val fingerprint: String,
    val communityKey: String? = null,
)

data class RealCatalogResolvedSnapshot(
    val communities: List<RealCatalogResolvedItem>,
    val meetings: List<RealCatalogResolvedItem>,
)
