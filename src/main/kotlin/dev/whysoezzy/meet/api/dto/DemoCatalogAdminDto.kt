package dev.whysoezzy.meet.api.dto

import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapCommand
import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapResult
import jakarta.validation.constraints.NotNull
import java.time.Instant
import java.time.LocalDate

data class DemoCatalogBootstrapRequest(
    @field:NotNull
    val scheduleAnchorDate: LocalDate?,
    @field:NotNull
    val catalogValidThrough: Instant?,
    val confirmReschedule: Boolean = false,
) {
    fun toCommand() = DemoCatalogBootstrapCommand(
        requireNotNull(scheduleAnchorDate),
        requireNotNull(catalogValidThrough),
        confirmReschedule,
    )
}

data class DemoCatalogRootCountsDto(
    val created: Int,
    val updated: Int,
    val unchanged: Int,
)

data class DemoCatalogRelationshipCountsDto(
    val added: Int,
    val removed: Int,
    val unchanged: Int,
)

data class DemoCatalogRootsDto(
    val tags: DemoCatalogRootCountsDto,
    val users: DemoCatalogRootCountsDto,
    val communities: DemoCatalogRootCountsDto,
    val meetings: DemoCatalogRootCountsDto,
    val adBlocks: DemoCatalogRootCountsDto,
)

data class DemoCatalogRelationshipsDto(
    val userInterests: DemoCatalogRelationshipCountsDto,
    val communityTags: DemoCatalogRelationshipCountsDto,
    val communitySubscribers: DemoCatalogRelationshipCountsDto,
    val meetingTags: DemoCatalogRelationshipCountsDto,
    val meetingParticipants: DemoCatalogRelationshipCountsDto,
    val meetingPersonHosts: DemoCatalogRelationshipCountsDto,
    val meetingCommunityHosts: DemoCatalogRelationshipCountsDto,
    val adBlockCommunities: DemoCatalogRelationshipCountsDto,
    val adBlockUsers: DemoCatalogRelationshipCountsDto,
)

data class DemoCatalogBootstrapResponse(
    val catalogName: String,
    val manifestVersion: String,
    val scheduleAnchorDate: LocalDate,
    val catalogValidThrough: Instant,
    val roots: DemoCatalogRootsDto,
    val relationships: DemoCatalogRelationshipsDto,
) {
    companion object {
        fun from(result: DemoCatalogBootstrapResult) = DemoCatalogBootstrapResponse(
            result.catalogName,
            result.manifestVersion,
            result.scheduleAnchorDate,
            result.catalogValidThrough,
            DemoCatalogRootsDto(
                result.roots.tags.toDto(),
                result.roots.users.toDto(),
                result.roots.communities.toDto(),
                result.roots.meetings.toDto(),
                result.roots.adBlocks.toDto(),
            ),
            DemoCatalogRelationshipsDto(
                result.relationships.userInterests.toDto(),
                result.relationships.communityTags.toDto(),
                result.relationships.communitySubscribers.toDto(),
                result.relationships.meetingTags.toDto(),
                result.relationships.meetingParticipants.toDto(),
                result.relationships.meetingPersonHosts.toDto(),
                result.relationships.meetingCommunityHosts.toDto(),
                result.relationships.adBlockCommunities.toDto(),
                result.relationships.adBlockUsers.toDto(),
            ),
        )
    }
}

private fun dev.whysoezzy.meet.demo.catalog.RootCounts.toDto() =
    DemoCatalogRootCountsDto(created, updated, unchanged)

private fun dev.whysoezzy.meet.demo.catalog.RelationshipCounts.toDto() =
    DemoCatalogRelationshipCountsDto(added, removed, unchanged)
