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
                target = currentRoots(loaded.manifest.catalogKey),
            )
        }
        state?.let(::checkOwnedState)
        validateTransition(loaded.manifest, state, request.expectedGeneration, now)
        val cutoff = deriveCutoff(loaded.manifest, state, now)
        val existing = state?.let { currentRoots(loaded.manifest.catalogKey) } ?: emptyMap()
        return response(
            loaded.manifest,
            loaded.digest,
            state?.generation ?: 0,
            cutoff,
            changed = state?.currentDigest != loaded.digest,
            existing = existing,
            target = plannedRoots(existing, loaded.manifest),
        )
    }

    @Transactional(timeout = 30)
    fun apply(request: RealCatalogApplyRequest): RealCatalogOperationResponse {
        if (!properties.enabled) throw NotFoundException("Real catalog is disabled")
        if (properties.targetEnvironment.isBlank()) throw ConflictException("Real catalog target is not configured")

        val loaded = load(request.revision, request.digest)
        validateApprovedMediaHosts(loaded.manifest)
        val now = clock.instant()
        val verifier = RealCatalogAttestationVerifier(properties.attestationSecret)
        verifier.verify(
            request.contentApprovalRef,
            RealCatalogAttestationVerifier.CONTENT,
            loaded.manifest.catalogKey,
            loaded.digest,
            loaded.manifest.intent,
            properties.targetEnvironment,
            now,
        ).also {
            if (it.recoveryPointId != null || it.recoveryProofSchema != null || it.recoveryProofDigest != null) {
                throw ConflictException("Content approval binding conflict")
            }
        }
        val recovery = verifier.verify(
            request.recoveryPointRef,
            RealCatalogAttestationVerifier.RECOVERY,
            loaded.manifest.catalogKey,
            loaded.digest,
            loaded.manifest.intent,
            properties.targetEnvironment,
            now,
        )
        if (recovery.recoveryPointId == null ||
            recovery.recoveryProofSchema != RealCatalogAttestationVerifier.RECOVERY_PROOF_SCHEMA ||
            recovery.recoveryProofDigest.isNullOrBlank()
        ) {
            throw ConflictException("Recovery attestation binding conflict")
        }
        val mutation = verifier.verify(
            request.mutationAuthorizationRef,
            RealCatalogAttestationVerifier.MUTATION,
            loaded.manifest.catalogKey,
            loaded.digest,
            loaded.manifest.intent,
            properties.targetEnvironment,
            now,
        )
        if (mutation.recoveryPointId != recovery.recoveryPointId ||
            mutation.recoveryProofSchema != recovery.recoveryProofSchema ||
            mutation.recoveryProofDigest != recovery.recoveryProofDigest
        ) {
            throw ConflictException("Mutation authorization binding conflict")
        }
        if (!advisoryLock.tryAcquire()) throw ConflictException("Real catalog is busy")
        val manifest = loaded.manifest
        var state = stateRepository.findById(manifest.catalogKey).orElse(null)

        if (state?.currentDigest == loaded.digest) {
            checkOwnedState(state)
            return response(
                manifest,
                loaded.digest,
                state.generation,
                state.discoverableUntil,
                changed = false,
                existing = currentRoots(manifest.catalogKey),
                target = currentRoots(manifest.catalogKey),
            )
        }

        state?.let(::checkOwnedState)
        validateTransition(manifest, state, request.expectedGeneration, now)
        val cutoff = deriveCutoff(manifest, state, now)
        val oldCommunities = communityRepository.findAllByRealCatalogKey(manifest.catalogKey)
            .associateBy { it.realCatalogItemKey!! }
        val oldMeetings = meetingRepository.findAllByRealCatalogKey(manifest.catalogKey)
            .associateBy { it.realCatalogItemKey!! }
        if (oldCommunities.keys.union(manifest.communities.map { it.logicalKey }.toSet()).size >
            RealCatalogManifestValidator.MAX_COMMUNITIES
        ) {
            throw ConflictException("Resolved catalog has too many communities")
        }
        if (oldMeetings.keys.union(manifest.meetings.map { it.logicalKey }.toSet()).size >
            RealCatalogManifestValidator.MAX_MEETINGS
        ) {
            throw ConflictException("Resolved catalog has too many meetings")
        }
        val priorRoots = currentRoots(manifest.catalogKey)
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

        val manifestCommunityKeys = manifest.communities.map { it.logicalKey }.toSet()
        val manifestMeetingKeys = manifest.meetings.map { it.logicalKey }.toSet()
        oldCommunities.filterKeys { it !in manifestCommunityKeys }
            .values.forEach { it.realCatalogActive = false }
        oldMeetings.filterKeys { it !in manifestMeetingKeys }
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
        val targetRoots = currentRoots(manifest.catalogKey)
        return response(
            manifest,
            loaded.digest,
            nextGeneration,
            cutoff,
            changed = true,
            existing = priorRoots,
            target = targetRoots,
        )
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
                .flatMap { provenanceSources(it.source, it.provenance) }
                .mapNotNull { it.discoveryUseCutoff }
                .forEach(::add)
            manifest.meetings.filter { it.membership == RealCatalogMembership.ACTIVE }
                .flatMap { provenanceSources(it.source, it.provenance) }
                .mapNotNull { it.discoveryUseCutoff }
                .forEach(::add)
        }
        return cutoffs.minOrNull() ?: windowEnd
    }

    private fun provenanceSources(
        source: RealCatalogSource,
        provenance: RealCatalogFieldProvenance,
    ): List<RealCatalogSource> =
        listOfNotNull(
            source,
            provenance.title,
            provenance.description,
            provenance.image,
            provenance.organizer,
            provenance.schedule,
            provenance.location,
        )

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

    private data class RootSummary(
        val kind: String,
        val logicalKey: String,
        val entityId: Long?,
        val active: Boolean,
        val fingerprint: String,
        val communityKey: String? = null,
    ) {
        val responseKey: String
            get() = "${kind.lowercase()}:$logicalKey"
    }

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
        if (snapshot.communities.map { "community:${it.logicalKey}" }.distinct().size != snapshot.communities.size ||
            snapshot.meetings.map { "meeting:${it.logicalKey}" }.distinct().size != snapshot.meetings.size
        ) {
            throw ConflictException("Catalog ownership drift")
        }
        val communities = communityRepository.findAllByRealCatalogKey(state.catalogKey)
            .associateBy { it.realCatalogItemKey }
        val meetings = meetingRepository.findAllByRealCatalogKey(state.catalogKey)
            .associateBy { it.realCatalogItemKey }
        if (communities.keys.any { it == null } || meetings.keys.any { it == null }) {
            throw ConflictException("Catalog ownership drift")
        }
        if (communities.size != snapshot.communities.size || meetings.size != snapshot.meetings.size) {
            throw ConflictException("Catalog ownership drift")
        }
        snapshot.communities.forEach { expected ->
            val actual = communities[expected.logicalKey]
                ?: throw ConflictException("Catalog ownership drift")
            if (actual.id != expected.entityId ||
                actual.realCatalogKey != state.catalogKey ||
                actual.realCatalogItemKey != expected.logicalKey ||
                actual.realCatalogActive != (expected.membership == RealCatalogMembership.ACTIVE) ||
                actual.demoCatalogKey != null ||
                actual.realCatalogFingerprint != fingerprint(actual)
            ) {
                throw ConflictException("Catalog ownership drift")
            }
            if (actual.realCatalogFingerprint != expected.fingerprint) {
                throw ConflictException("Catalog ownership drift")
            }
        }
        snapshot.meetings.forEach { expected ->
            val actual = meetings[expected.logicalKey]
                ?: throw ConflictException("Catalog ownership drift")
            if (actual.id != expected.entityId ||
                actual.realCatalogKey != state.catalogKey ||
                actual.realCatalogItemKey != expected.logicalKey ||
                actual.realCatalogActive != (expected.membership == RealCatalogMembership.ACTIVE) ||
                actual.demoCatalogKey != null ||
                actual.source != EventSource.MANUAL ||
                actual.sourceExternalId != "closed-beta-real:${expected.logicalKey}" ||
                actual.personHost != null ||
                actual.realCatalogFingerprint != fingerprint(actual) ||
                actual.communityHost?.realCatalogItemKey != expected.communityKey
            ) {
                throw ConflictException("Catalog ownership drift")
            }
            if (actual.realCatalogFingerprint != expected.fingerprint) {
                throw ConflictException("Catalog ownership drift")
            }
        }
    }

    private fun currentRoots(catalogKey: String): Map<String, RootSummary> {
        val communities = communityRepository.findAllByRealCatalogKey(catalogKey).associateBy {
            it.realCatalogItemKey ?: throw ConflictException("Catalog ownership drift")
        }
        val meetings = meetingRepository.findAllByRealCatalogKey(catalogKey).associateBy {
            it.realCatalogItemKey ?: throw ConflictException("Catalog ownership drift")
        }
        return (
            communities.values.map {
                RootSummary(
                    kind = "COMMUNITY",
                    logicalKey = it.realCatalogItemKey!!,
                    entityId = it.id,
                    active = it.realCatalogActive == true,
                    fingerprint = fingerprint(it),
                )
            } +
                meetings.values.map {
                    RootSummary(
                        kind = "MEETING",
                        logicalKey = it.realCatalogItemKey!!,
                        entityId = it.id,
                        active = it.realCatalogActive == true,
                        fingerprint = fingerprint(it),
                        communityKey = it.communityHost?.realCatalogItemKey,
                    )
                }
            ).associateBy { it.responseKey }
    }

    private fun plannedRoots(
        existing: Map<String, RootSummary>,
        manifest: RealCatalogManifest,
    ): Map<String, RootSummary> {
        val planned = existing.mapValues { (_, value) -> value.copy(active = false) }.toMutableMap()
        manifest.communities.forEach { item ->
            val old = existing["community:${item.logicalKey}"]
            val root = RootSummary(
                kind = "COMMUNITY",
                logicalKey = item.logicalKey,
                entityId = old?.entityId,
                active = item.membership == RealCatalogMembership.ACTIVE,
                fingerprint = fingerprint(item),
            )
            planned[root.responseKey] = root
        }
        manifest.meetings.forEach { item ->
            val old = existing["meeting:${item.logicalKey}"]
            val root = RootSummary(
                kind = "MEETING",
                logicalKey = item.logicalKey,
                entityId = old?.entityId,
                active = item.membership == RealCatalogMembership.ACTIVE,
                fingerprint = fingerprint(item),
                communityKey = item.communityKey,
            )
            planned[root.responseKey] = root
        }
        return planned
    }

    private fun response(
        manifest: RealCatalogManifest,
        digest: String,
        generation: Long,
        cutoff: Instant,
        changed: Boolean,
        existing: Map<String, RootSummary>,
        target: Map<String, RootSummary>,
    ) = RealCatalogOperationResponse(
        catalogKey = manifest.catalogKey,
        digest = digest,
        generation = generation,
        changed = changed,
        activeCommunities = target.values.count { it.kind == "COMMUNITY" && it.active },
        activeMeetings = target.values.count { it.kind == "MEETING" && it.active },
        retiredCommunities = target.values.count { it.kind == "COMMUNITY" && !it.active },
        retiredMeetings = target.values.count { it.kind == "MEETING" && !it.active },
        discoverableUntil = cutoff.toString(),
        changedKeys = (existing.keys + target.keys)
            .distinct()
            .filter { existing[it] != target[it] }
            .take(100),
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
        val fields = when (value) {
            is RealCatalogCommunity -> listOf(
                "community", value.logicalKey, value.name, value.description, value.imageUrl,
                value.tags.sorted().joinToString(","), RealCatalogManifestValidator.CATALOG_KEY,
                (value.membership == RealCatalogMembership.ACTIVE).toString(), "",
            )
            is RealCatalogMeeting -> listOf(
                "meeting", value.logicalKey, value.title, value.description, value.imageUrl,
                value.startAt.toEpochMilli().toString(), value.endAt?.toEpochMilli()?.toString() ?: "",
                value.dateLabel, value.address, value.latitude.toString(), value.longitude.toString(),
                value.capacity.toString(), value.isOnline.toString(), value.status.name,
                value.tags.sorted().joinToString(","), value.communityKey, value.externalUrl ?: "",
                EventSource.MANUAL.name, "closed-beta-real:${value.logicalKey}", "null-person-host",
                RealCatalogManifestValidator.CATALOG_KEY,
                (value.membership == RealCatalogMembership.ACTIVE).toString(), "",
            )
            is Community -> listOf(
                "community", value.realCatalogItemKey ?: "", value.name, value.description, value.imageUrl,
                value.tags.map { it.text }.sorted().joinToString(","),
                value.realCatalogKey ?: "", value.realCatalogActive.toString(), value.demoCatalogKey ?: "",
            )
            is Meeting -> listOf(
                "meeting", value.realCatalogItemKey ?: "", value.title, value.description, value.imageUrl,
                value.time.toString(), value.endsAt?.toString() ?: "", value.date, value.address,
                value.latitude.toString(), value.longitude.toString(), value.capacity.toString(),
                value.isOnline.toString(), value.status.name,
                value.tags.map { it.text }.sorted().joinToString(","),
                value.communityHost?.realCatalogItemKey ?: "", value.externalUrl ?: "",
                value.source.name, value.sourceExternalId ?: "", value.personHost?.id?.toString() ?: "null-person-host",
                value.realCatalogKey ?: "", value.realCatalogActive.toString(), value.demoCatalogKey ?: "",
            )
            else -> error("Unsupported catalog fingerprint")
        }
        val canonical = fields.joinToString("") { "${it.length}:$it;" }
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
