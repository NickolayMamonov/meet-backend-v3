package dev.whysoezzy.meet.demo.catalog

import java.time.Instant
import java.time.LocalDate

data class RootCounts(
    val created: Int = 0,
    val updated: Int = 0,
    val unchanged: Int = 0,
)

data class RelationshipCounts(
    val added: Int = 0,
    val removed: Int = 0,
    val unchanged: Int = 0,
)

data class DemoCatalogBootstrapCommand(
    val scheduleAnchorDate: LocalDate,
    val catalogValidThrough: Instant,
    val confirmReschedule: Boolean = false,
)

data class DemoCatalogBootstrapResult(
    val catalogName: String,
    val manifestVersion: String,
    val scheduleAnchorDate: LocalDate,
    val catalogValidThrough: Instant,
    val roots: RootSummary,
    val relationships: RelationshipSummary,
)

data class RootSummary(
    val tags: RootCounts,
    val users: RootCounts,
    val communities: RootCounts,
    val meetings: RootCounts,
    val adBlocks: RootCounts,
)

data class RelationshipSummary(
    val userInterests: RelationshipCounts,
    val communityTags: RelationshipCounts,
    val communitySubscribers: RelationshipCounts,
    val meetingTags: RelationshipCounts,
    val meetingParticipants: RelationshipCounts,
    val meetingPersonHosts: RelationshipCounts,
    val meetingCommunityHosts: RelationshipCounts,
    val adBlockCommunities: RelationshipCounts,
    val adBlockUsers: RelationshipCounts,
)
