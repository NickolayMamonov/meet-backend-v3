package dev.whysoezzy.meet.catalog

import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.config.RealCatalogProperties
import dev.whysoezzy.meet.domain.entity.Community
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.Tag
import dev.whysoezzy.meet.domain.repository.CommunityRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.TagRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Isolation
import org.springframework.transaction.annotation.Transactional
import tools.jackson.databind.ObjectMapper
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.net.URI

@Service
class RealCatalogService(
    private val loader: RealCatalogManifestLoader,
    private val stateRepository: RealCatalogStateRepository,
    private val revisionRepository: RealCatalogRevisionRepository,
    private val communityRepository: CommunityRepository,
    private val meetingRepository: MeetingRepository,
    private val tagRepository: TagRepository,
    private val advisoryLock: RealCatalogAdvisoryLock,
    private val objectMapper: ObjectMapper,
    private val clock: Clock,
    private val properties: RealCatalogProperties,
) {
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    fun preview(request: RealCatalogPreviewRequest): RealCatalogOperationResponse {
        if (!properties.enabled) throw NotFoundException("Real catalog is disabled")
        val loaded = load(request.revision, request.digest)
        validateApprovedMediaHosts(loaded.manifest)
        val state = stateRepository.findById(loaded.manifest.catalogKey).orElse(null)
        val now = clock.instant()
        if (state?.currentDigest == loaded.digest) {
            checkOwnedState(state)
            return response(
                loaded.manifest,
                loaded.digest,
                state.generation,
                state.discoverableUntil,
                changed = false,
                existing = currentRoots(loaded.manifest.catalogKey),
            )
        }
        state?.let(::checkOwnedState)
        validateTransition(loaded.manifest, state, request.expectedGeneration, now)
        val cutoff = deriveCutoff(loaded.manifest, state, now)
        return response(
            loaded.manifest,
            loaded.digest,
            state?.generation ?: 0,
            cutoff,
            changed = state?.currentDigest != loaded.digest,
            existing = state?.let { currentRoots(loaded.manifest.catalogKey) } ?: emptyMap(),
        )
    }

    @Transactional(timeout = 30)
    fun apply(request: RealCatalogApplyRequest): RealCatalogOperationResponse {
        if (!properties.enabled) throw NotFoundException("Real catalog is disabled")
        if (properties.targetEnvironment.isBlank()) throw ConflictException("Real catalog target is not configured")
        validateApprovalRef(request.contentApprovalRef, "content approval")
        validateApprovalRef(request.mutationAuthorizationRef, "mutation authorization")
        validateApprovalRef(request.recoveryPointRef, "recovery point")

        val loaded = load(request.revision, request.digest)
        validateApprovedMediaHosts(loaded.manifest)
        if (!advisoryLock.tryAcquire()) throw ConflictException("Real catalog is busy")
        val manifest = loaded.manifest
        var state = stateRepository.findById(manifest.catalogKey).orElse(null)
        val now = clock.instant()

        if (state?.currentDigest == loaded.digest) {
            checkOwnedState(state)
            return response(
                manifest,
                loaded.digest,
                state.generation,
                state.discoverableUntil,
                changed = false,
                existing = currentRoots(manifest.catalogKey),
            )
        }

        state?.let(::checkOwnedState)
        validateTransition(manifest, state, request.expectedGeneration, now)
        val cutoff = deriveCutoff(manifest, state, now)
        val nextGeneration = (state?.generation ?: 0) + 1
        if (state == null) {
            state = RealCatalogStateEntity(
                catalogKey = manifest.catalogKey,
                currentDigest = loaded.digest,
                generation = nextGeneration,
                currentIntent = manifest.intent,
                invitationAt = manifest.invitationAt,
                windowEndAt = manifest.windowEndAt,
                reviewAt = manifest.reviewAt,
                nextReviewAt = manifest.nextReviewAt,
                discoverableUntil = cutoff,
                ownerRole = manifest.ownerRole,
            )
            stateRepository.save(state)
        } else {
            state.currentDigest = loaded.digest
            state.generation = nextGeneration
            state.currentIntent = manifest.intent
            state.invitationAt = manifest.invitationAt
            state.windowEndAt = manifest.windowEndAt
            state.reviewAt = manifest.reviewAt
            state.nextReviewAt = manifest.nextReviewAt
            state.discoverableUntil = cutoff
            state.ownerRole = manifest.ownerRole
        }

        val revision = RealCatalogRevisionEntity(
            digest = loaded.digest,
            catalogKey = manifest.catalogKey,
            revisionLabel = manifest.revisionLabel,
            schemaVersion = manifest.schemaVersion,
            intent = manifest.intent,
            predecessorDigest = manifest.predecessorDigest,
            manifestBytes = loaded.bytes,
            resolvedSnapshot = "{}",
            invitationAt = manifest.invitationAt,
            windowEndAt = manifest.windowEndAt,
            reviewAt = manifest.reviewAt,
            nextReviewAt = manifest.nextReviewAt,
            discoverableUntil = cutoff,
            contentApprovalRef = request.contentApprovalRef,
            mutationApprovalRef = request.mutationAuthorizationRef,
            recoveryPointRef = request.recoveryPointRef,
            appliedAt = now,
            generation = nextGeneration,
        )
        revisionRepository.save(revision)
        revisionRepository.flush()

        val oldCommunities = communityRepository.findAllByRealCatalogKey(manifest.catalogKey)
            .associateBy { it.realCatalogItemKey!! }
        val oldMeetings = meetingRepository.findAllByRealCatalogKey(manifest.catalogKey)
            .associateBy { it.realCatalogItemKey!! }
        val communities = oldCommunities.toMutableMap()
        val meetings = oldMeetings.toMutableMap()

        manifest.communities.forEach { item ->
            val community = applyCommunity(manifest, item, communities[item.logicalKey])
            communities[item.logicalKey] = community
            communityRepository.save(community)
        }
        manifest.meetings.forEach { item ->
            val community = communities[item.communityKey]
                ?: throw ConflictException("Meeting community is not owned by this catalog")
            val meeting = applyMeeting(manifest, item, meetings[item.logicalKey], community)
            meetings[item.logicalKey] = meeting
            meetingRepository.save(meeting)
        }

        oldCommunities.filterKeys { it !in manifest.communities.map { item -> item.logicalKey }.toSet() }
            .values.forEach { it.realCatalogActive = false }
        oldMeetings.filterKeys { it !in manifest.meetings.map { item -> item.logicalKey }.toSet() }
            .values.forEach { it.realCatalogActive = false }

        meetings.values.filter { it.realCatalogActive == true }.forEach {
            if (it.communityHost?.realCatalogActive != true) {
                throw ConflictException("Active meeting requires an active catalog community")
            }
        }
        communityRepository.flush()
        meetingRepository.flush()
        val snapshot = RealCatalogResolvedSnapshot(
            communities = communities.values
                .sortedBy { it.realCatalogItemKey }
                .map { it.toSnapshot() },
            meetings = meetings.values
                .sortedBy { it.realCatalogItemKey }
                .map { it.toSnapshot() },
        )
        revision.resolvedSnapshot = objectMapper.writeValueAsString(snapshot)
        revisionRepository.save(revision)
        revisionRepository.flush()
        return response(manifest, loaded.digest, nextGeneration, cutoff, true, currentRoots(manifest.catalogKey))
    }

    private fun load(revision: String, expectedDigest: String): RealCatalogLoadedManifest {
        if (!expectedDigest.matches(Regex("^[0-9a-f]{64}$"))) throw BadRequestException("Invalid catalog digest")
        val loaded = runCatching { loader.load(revision) }
            .getOrElse { throw BadRequestException("Invalid real catalog resource") }
        if (loaded.digest != expectedDigest) throw ConflictException("Catalog digest conflict")
        return loaded
    }

    private fun validateTransition(
        manifest: RealCatalogManifest,
        state: RealCatalogStateEntity?,
        expectedGeneration: Long,
        now: Instant,
    ) {
        if (state == null) {
            if (manifest.intent != RealCatalogIntent.INITIAL) throw ConflictException("Catalog state is missing")
            if (expectedGeneration != 0L) throw ConflictException("Catalog generation conflict")
        } else {
            if (expectedGeneration != state.generation) throw ConflictException("Catalog generation conflict")
            if (manifest.predecessorDigest != state.currentDigest) throw ConflictException("Catalog predecessor conflict")
            when (manifest.intent) {
                RealCatalogIntent.INITIAL -> throw ConflictException("Catalog is already initialized")
                RealCatalogIntent.REVIEW -> {
                    if (manifest.windowEndAt != state.windowEndAt || manifest.invitationAt != state.invitationAt) {
                        throw ConflictException("Review cannot change the invitation window")
                    }
                    if (!manifest.reviewAt.isAfter(state.reviewAt) || !manifest.reviewAt.isBefore(state.windowEndAt)) {
                        throw ConflictException("Review is outside the active window")
                    }
                }
                RealCatalogIntent.NEW_WINDOW -> {
                    if (manifest.invitationAt == state.invitationAt &&
                        manifest.windowEndAt == state.windowEndAt
                    ) {
                        throw ConflictException("New window must change the invitation window")
                    }
                    if (!manifest.windowEndAt.isAfter(now)) throw ConflictException("New window has expired")
                }
                RealCatalogIntent.CORRECT -> {
                    if (manifest.windowEndAt != state.windowEndAt ||
                        manifest.invitationAt != state.invitationAt ||
                        manifest.reviewAt != state.reviewAt ||
                        manifest.nextReviewAt != state.nextReviewAt ||
                        manifest.ownerRole != state.ownerRole
                    ) {
                        throw ConflictException("Correction cannot renew catalog freshness")
                    }
                    validateCorrectionMembership(manifest, state.windowEndAt)
                }
            }
        }
        if (manifest.intent != RealCatalogIntent.CORRECT && !manifest.windowEndAt.isAfter(now)) {
            throw ConflictException("Catalog window has expired")
        }
    }

    private fun validateCorrectionMembership(manifest: RealCatalogManifest, windowEndAt: Instant) {
        val existingCommunities = communityRepository.findAllByRealCatalogKey(manifest.catalogKey)
            .associateBy { it.realCatalogItemKey }
        val existingMeetings = meetingRepository.findAllByRealCatalogKey(manifest.catalogKey)
            .associateBy { it.realCatalogItemKey }
        manifest.communities.forEach {
            val old = existingCommunities[it.logicalKey] ?: throw ConflictException("Correction cannot add a community")
            if (old.realCatalogActive == false && it.membership == RealCatalogMembership.ACTIVE) {
                throw ConflictException("Correction cannot reactivate a community")
            }
        }
        manifest.meetings.forEach {
            val old = existingMeetings[it.logicalKey] ?: throw ConflictException("Correction cannot add a meeting")
            if (old.realCatalogActive == false && it.membership == RealCatalogMembership.ACTIVE) {
                throw ConflictException("Correction cannot reactivate a meeting")
            }
            if (it.membership == RealCatalogMembership.ACTIVE && !it.startAt.isAfter(windowEndAt)) {
                throw ConflictException("Correction cannot keep a pre-window meeting active")
            }
        }
    }

    private fun deriveCutoff(
        manifest: RealCatalogManifest,
        state: RealCatalogStateEntity?,
        now: Instant,
    ): Instant {
        if (manifest.intent == RealCatalogIntent.CORRECT && state != null) {
            return minOf(state.discoverableUntil, activeContentCutoff(manifest, state.windowEndAt, state.reviewAt))
        }
        val cutoff = activeContentCutoff(manifest, manifest.windowEndAt, manifest.reviewAt)
        if (manifest.intent != RealCatalogIntent.CORRECT && !cutoff.isAfter(now)) {
            throw ConflictException("Catalog has no fresh discovery window")
        }
        return cutoff
    }

    private fun activeContentCutoff(manifest: RealCatalogManifest, windowEnd: Instant, reviewAt: Instant): Instant {
        val cutoffs = buildList {
            add(windowEnd)
            add(reviewAt.plus(Duration.ofDays(7)))
            manifest.communities.filter { it.membership == RealCatalogMembership.ACTIVE }
                .mapNotNullTo(this) { it.source.discoveryUseCutoff }
            manifest.meetings.filter { it.membership == RealCatalogMembership.ACTIVE }
                .mapNotNullTo(this) { it.source.discoveryUseCutoff }
        }
        return cutoffs.minOrNull() ?: windowEnd
    }

    private fun applyCommunity(
        manifest: RealCatalogManifest,
        item: RealCatalogCommunity,
        existing: Community?,
    ): Community {
        val community = existing ?: communityRepository.findByRealCatalogKeyAndRealCatalogItemKey(
            manifest.catalogKey,
            item.logicalKey,
        ) ?: Community(item.name, item.description, item.imageUrl)
        if (community.realCatalogKey != null && community.realCatalogKey != manifest.catalogKey) {
            throw ConflictException("Catalog ownership conflict")
        }
        community.name = item.name
        community.description = item.description
        community.imageUrl = item.imageUrl
        community.realCatalogKey = manifest.catalogKey
        community.realCatalogItemKey = item.logicalKey
        community.realCatalogActive = item.membership == RealCatalogMembership.ACTIVE
        community.realCatalogFingerprint = fingerprint(item)
        community.tags = item.tags.map(::tag).toMutableSet()
        community.demoCatalogKey = null
        return community
    }

    private fun applyMeeting(
        manifest: RealCatalogManifest,
        item: RealCatalogMeeting,
        existing: Meeting?,
        community: Community,
    ): Meeting {
        val sourceExternalId = "closed-beta-real:${item.logicalKey}"
        val identity = meetingRepository.findBySourceAndSourceExternalId(EventSource.MANUAL, sourceExternalId)
        if (identity != null && identity !== existing &&
            (identity.realCatalogKey != manifest.catalogKey || identity.realCatalogItemKey != item.logicalKey)
        ) {
            throw ConflictException("Meeting source identity conflict")
        }
        val meeting = existing ?: identity ?: Meeting(
            title = item.title,
            description = item.description,
            imageUrl = item.imageUrl,
            time = item.startAt.toEpochMilli(),
            date = item.dateLabel,
            address = item.address,
            latitude = item.latitude,
            longitude = item.longitude,
            capacity = item.capacity,
        )
        if (meeting.participants.size > item.capacity) throw ConflictException("Catalog capacity is below participation")
        meeting.title = item.title
        meeting.description = item.description
        meeting.imageUrl = item.imageUrl
        meeting.time = item.startAt.toEpochMilli()
        meeting.endsAt = item.endAt?.toEpochMilli()
        meeting.date = item.dateLabel
        meeting.address = item.address
        meeting.latitude = item.latitude
        meeting.longitude = item.longitude
        meeting.capacity = item.capacity
        meeting.status = item.status
        meeting.externalUrl = item.externalUrl
        meeting.isOnline = item.isOnline
        meeting.source = EventSource.MANUAL
        meeting.sourceExternalId = sourceExternalId
        meeting.personHost = null
        meeting.communityHost = community
        meeting.tags = item.tags.map(::tag).toMutableSet()
        meeting.realCatalogKey = manifest.catalogKey
        meeting.realCatalogItemKey = item.logicalKey
        meeting.realCatalogActive = item.membership == RealCatalogMembership.ACTIVE
        meeting.realCatalogFingerprint = fingerprint(item)
        meeting.demoCatalogKey = null
        return meeting
    }

    private fun tag(text: String): Tag = tagRepository.findByText(text) ?: tagRepository.save(Tag(text))

    private fun checkOwnedState(state: RealCatalogStateEntity) {
        val revision = revisionRepository.findById(state.currentDigest)
            .orElseThrow { ConflictException("Catalog ownership drift") }
        if (revision.catalogKey != state.catalogKey ||
            revision.generation != state.generation ||
            revision.intent != state.currentIntent ||
            revision.discoverableUntil != state.discoverableUntil
        ) {
            throw ConflictException("Catalog ownership drift")
        }
        val snapshot = runCatching {
            objectMapper.readValue(revision.resolvedSnapshot, RealCatalogResolvedSnapshot::class.java)
        }.getOrElse { throw ConflictException("Catalog ownership drift") }
        val communities = communityRepository.findAllByRealCatalogKey(state.catalogKey)
            .associateBy { it.realCatalogItemKey }
        val meetings = meetingRepository.findAllByRealCatalogKey(state.catalogKey)
            .associateBy { it.realCatalogItemKey }
        if (communities.size != snapshot.communities.size || meetings.size != snapshot.meetings.size) {
            throw ConflictException("Catalog ownership drift")
        }
        snapshot.communities.forEach { expected ->
            val actual = communities[expected.logicalKey]
                ?: throw ConflictException("Catalog ownership drift")
            if (actual.id != expected.entityId ||
                actual.realCatalogActive != (expected.membership == RealCatalogMembership.ACTIVE) ||
                actual.realCatalogFingerprint != expected.fingerprint
            ) {
                throw ConflictException("Catalog ownership drift")
            }
        }
        snapshot.meetings.forEach { expected ->
            val actual = meetings[expected.logicalKey]
                ?: throw ConflictException("Catalog ownership drift")
            if (actual.id != expected.entityId ||
                actual.realCatalogActive != (expected.membership == RealCatalogMembership.ACTIVE) ||
                actual.realCatalogFingerprint != expected.fingerprint ||
                actual.communityHost?.realCatalogItemKey != expected.communityKey
            ) {
                throw ConflictException("Catalog ownership drift")
            }
        }
    }

    private fun currentRoots(catalogKey: String): Map<String, Boolean> =
        (communityRepository.findAllByRealCatalogKey(catalogKey).mapNotNull { it.realCatalogItemKey?.let { key -> "community:$key" to (it.realCatalogActive == true) } } +
            meetingRepository.findAllByRealCatalogKey(catalogKey).mapNotNull { it.realCatalogItemKey?.let { key -> "meeting:$key" to (it.realCatalogActive == true) } }).toMap()

    private fun response(
        manifest: RealCatalogManifest,
        digest: String,
        generation: Long,
        cutoff: Instant,
        changed: Boolean,
        existing: Map<String, Boolean>,
    ) = RealCatalogOperationResponse(
        catalogKey = manifest.catalogKey,
        digest = digest,
        generation = generation,
        changed = changed,
        activeCommunities = manifest.communities.count { it.membership == RealCatalogMembership.ACTIVE },
        activeMeetings = manifest.meetings.count { it.membership == RealCatalogMembership.ACTIVE },
        retiredCommunities = manifest.communities.count { it.membership == RealCatalogMembership.RETIRED } +
            existing.count { it.key.startsWith("community:") && !it.value },
        retiredMeetings = manifest.meetings.count { it.membership == RealCatalogMembership.RETIRED } +
            existing.count { it.key.startsWith("meeting:") && !it.value },
        discoverableUntil = cutoff.toString(),
        changedKeys = (manifest.communities.map { "community:${it.logicalKey}" } + manifest.meetings.map { "meeting:${it.logicalKey}" })
            .distinct().take(100),
        conflicts = emptyList(),
    )

    private fun Community.toSnapshot() = RealCatalogResolvedItem(
        kind = "COMMUNITY",
        logicalKey = realCatalogItemKey ?: error("community key missing"),
        entityId = id,
        membership = if (realCatalogActive == true) RealCatalogMembership.ACTIVE else RealCatalogMembership.RETIRED,
        fingerprint = realCatalogFingerprint ?: "",
    )

    private fun Meeting.toSnapshot() = RealCatalogResolvedItem(
        kind = "MEETING",
        logicalKey = realCatalogItemKey ?: error("meeting key missing"),
        entityId = id,
        membership = if (realCatalogActive == true) RealCatalogMembership.ACTIVE else RealCatalogMembership.RETIRED,
        fingerprint = realCatalogFingerprint ?: "",
        communityKey = communityHost?.realCatalogItemKey,
    )

    private fun fingerprint(value: Any): String {
        val canonical = when (value) {
            is RealCatalogCommunity -> listOf(
                "community", value.logicalKey, value.name, value.description, value.imageUrl,
                value.tags.sorted().joinToString(","), value.membership.name,
            )
            is RealCatalogMeeting -> listOf(
                "meeting", value.logicalKey, value.title, value.description, value.imageUrl,
                value.startAt.toEpochMilli().toString(), value.endAt?.toEpochMilli()?.toString() ?: "",
                value.sourceZone, value.dateLabel, value.address, value.latitude.toString(), value.longitude.toString(),
                value.capacity.toString(), value.isOnline.toString(), value.status.name,
                value.tags.sorted().joinToString(","), value.communityKey, value.externalUrl ?: "", value.membership.name,
            )
            else -> error("Unsupported catalog fingerprint")
        }.joinToString("") { "${it.length}:$it;" }
        return MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun validateApprovalRef(value: String, label: String) {
        if (!value.matches(Regex("^[A-Za-z0-9._:/-]{1,160}$"))) throw BadRequestException("Invalid $label reference")
    }

    private fun validateApprovedMediaHosts(manifest: RealCatalogManifest) {
        val allowed = properties.approvedMediaHosts.map(String::lowercase).toSet()
        if (allowed.isEmpty()) throw ConflictException("Real catalog media hosts are not configured")
        val urls = manifest.communities.map { it.imageUrl } + manifest.meetings.map { it.imageUrl }
        if (urls.any { URI(it).host?.lowercase() !in allowed }) {
            throw ConflictException("Real catalog media host is not approved")
        }
    }
}
