package dev.whysoezzy.meet.demo.catalog

import dev.whysoezzy.meet.config.DemoCatalogProperties
import dev.whysoezzy.meet.domain.entity.AdBlock
import dev.whysoezzy.meet.domain.entity.Community
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.Tag
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.AdBlockRepository
import dev.whysoezzy.meet.domain.repository.CommunityRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.TagRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.api.error.ConflictException
import jakarta.persistence.EntityManager
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.Clock

@Service
class DemoCatalogBootstrapService(
    private val properties: DemoCatalogProperties,
    private val stateRepository: DemoCatalogStateRepository,
    private val tagRepository: TagRepository,
    private val userRepository: UserRepository,
    private val communityRepository: CommunityRepository,
    private val meetingRepository: MeetingRepository,
    private val adBlockRepository: AdBlockRepository,
    private val jdbcTemplate: JdbcTemplate,
    private val entityManager: EntityManager,
    private val advisoryLock: DemoCatalogAdvisoryLock,
    private val validator: DemoCatalogManifestValidator,
    private val clock: Clock,
) {
    private val manifest = BetaDemoCatalog.manifest
    private val compiler = DemoCatalogScheduleCompiler(clock)

    @Transactional
    fun bootstrap(command: DemoCatalogBootstrapCommand): DemoCatalogBootstrapResult {
        if (!advisoryLock.tryAcquire()) throw ConflictException("Demo catalog is busy")
        val state = stateRepository.findById(manifest.catalogName).orElse(null)
        if (
            state != null &&
            !command.confirmReschedule &&
            (state.scheduleAnchorDate != command.scheduleAnchorDate ||
                state.catalogValidThrough != command.catalogValidThrough)
        ) {
            throw ConflictException("Demo catalog schedule conflicts with applied state")
        }
        try {
            validator.validate(manifest, properties.allowedMediaHosts)
            val compiledMeetings = compiler.compile(
                manifest,
                command.scheduleAnchorDate,
                command.catalogValidThrough,
            )
            val resolved = preflight()
            val roots = upsertRoots(resolved, compiledMeetings)
            val relationships = reconcileRelationships(resolved)
            entityManager.flush()
            stateRepository.save(
                state?.apply {
                    manifestVersion = manifest.manifestVersion
                    scheduleAnchorDate = command.scheduleAnchorDate
                    catalogValidThrough = command.catalogValidThrough
                    appliedAt = clock.instant()
                } ?: DemoCatalogState(
                    catalogName = manifest.catalogName,
                    manifestVersion = manifest.manifestVersion,
                    scheduleAnchorDate = command.scheduleAnchorDate,
                    catalogValidThrough = command.catalogValidThrough,
                    appliedAt = clock.instant(),
                ),
            )
            return DemoCatalogBootstrapResult(
                manifest.catalogName,
                manifest.manifestVersion,
                command.scheduleAnchorDate,
                command.catalogValidThrough,
                roots,
                relationships,
            )
        } catch (_: DataIntegrityViolationException) {
            throw ConflictException("Demo catalog cannot be applied")
        } catch (exception: IllegalArgumentException) {
            throw BadRequestException("Invalid demo catalog")
        }
    }

    private data class Resolved(
        val tags: Map<CatalogKey, Tag>,
        val users: Map<CatalogKey, User>,
        val communities: Map<CatalogKey, Community>,
        val meetings: Map<CatalogKey, Meeting>,
        val adBlocks: Map<CatalogKey, AdBlock>,
    )

    private fun preflight(): Resolved {
        val tagKeys = manifest.tags.map { it.key }
        val userKeys = manifest.users.map { it.key }
        val communityKeys = manifest.communities.map { it.key }
        val meetingKeys = manifest.meetings.map { it.key }
        val adKeys = manifest.adBlocks.map { it.key }
        val existingTags = tagRepository.findAllByDemoCatalogKeyIn(tagKeys.map(CatalogKey::value))
            .associateBy { CatalogKey(requireNotNull(it.demoCatalogKey)) }
        val existingUsers = userRepository.findAllByDemoCatalogKeyIn(userKeys.map(CatalogKey::value))
            .associateBy { CatalogKey(requireNotNull(it.demoCatalogKey)) }
        val existingCommunities = communityRepository.findAllByDemoCatalogKeyIn(communityKeys.map(CatalogKey::value))
            .associateBy { CatalogKey(requireNotNull(it.demoCatalogKey)) }
        val existingMeetings = meetingRepository.findAllByDemoCatalogKeyIn(meetingKeys.map(CatalogKey::value))
            .associateBy { CatalogKey(requireNotNull(it.demoCatalogKey)) }
        val existingAds = adBlockRepository.findAllByDemoCatalogKeyIn(adKeys.map(CatalogKey::value))
            .associateBy { CatalogKey(requireNotNull(it.demoCatalogKey)) }

        val desiredEmails = manifest.users.map { it.email.lowercase() }.toSet()
        userRepository.findAll()
            .filter { it.demoCatalogKey !in userKeys.map(CatalogKey::value).toSet() }
            .firstOrNull { it.email?.lowercase() in desiredEmails }
            ?.let { throw ConflictException("Demo catalog conflicts with existing data") }

        existingUsers.values.forEach { user ->
            val contaminated =
                user.phone != null ||
                    user.fcmToken != null ||
                    user.role != null ||
                    user.deletedAt != null ||
                    user.authVersion != 0L ||
                    user.socialMedia.isNotEmpty() ||
                    count("SELECT count(*) FROM auth_identities WHERE user_id = ?", user.id) > 0 ||
                    count("SELECT count(*) FROM refresh_tokens WHERE user_id = ?", user.id) > 0 ||
                    (user.phone != null && count("SELECT count(*) FROM otp_codes WHERE identifier = ?", user.phone) > 0)
            if (contaminated) throw ConflictException("Demo catalog conflicts with existing data")
        }
        manifest.users.forEach {
            if (
                count(
                    "SELECT count(*) FROM auth_identities WHERE lower(normalized_identifier) = lower(?)",
                    it.email,
                ) > 0
            ) {
                throw ConflictException("Demo catalog conflicts with existing data")
            }
        }

        val resolvedTags = manifest.tags.associate { desired ->
            val owned = existingTags[desired.key]
            val byText = tagRepository.findByText(desired.text)
            if (owned != null && owned.text != desired.text) throw ConflictException("Demo catalog conflicts with existing data")
            if (byText != null && byText.demoCatalogKey != null && byText.demoCatalogKey != desired.key.value) {
                throw ConflictException("Demo catalog conflicts with existing data")
            }
            desired.key to (owned ?: byText ?: Tag(desired.text, desired.key.value))
        }
        return Resolved(
            tags = resolvedTags,
            users = existingUsers,
            communities = existingCommunities,
            meetings = existingMeetings,
            adBlocks = existingAds,
        )
    }

    private fun upsertRoots(
        resolved: Resolved,
        compiledMeetings: Map<CatalogKey, CompiledMeeting>,
    ): RootSummary {
        val tags = RootCounter()
        val users = RootCounter()
        val communities = RootCounter()
        val meetings = RootCounter()
        val ads = RootCounter()
        manifest.tags.forEach { desired ->
            val tag = resolved.tags.getValue(desired.key)
            if (tag.id == null) {
                tagRepository.save(tag)
                tags.created++
            } else if (tag.demoCatalogKey != null && tag.text != desired.text) {
                tag.text = desired.text
                tags.updated++
            } else {
                tags.unchanged++
            }
        }
        manifest.users.forEach { desired ->
            val user = resolved.users[desired.key]
            if (user == null) {
                userRepository.save(
                    User(
                        name = desired.name,
                        surname = desired.surname,
                        phone = null,
                        email = desired.email,
                        city = desired.city,
                        avatarUrl = desired.avatarUrl,
                        bio = desired.bio,
                        role = null,
                        showCommunities = true,
                        showMeetings = true,
                        notificationsEnabled = true,
                        fcmToken = null,
                        deletedAt = null,
                        authVersion = 0,
                        demoCatalogKey = desired.key.value,
                    ),
                )
                users.created++
            } else if (userChanged(user, desired)) {
                user.name = desired.name
                user.surname = desired.surname
                user.email = desired.email
                user.city = desired.city
                user.avatarUrl = desired.avatarUrl
                user.bio = desired.bio
                user.showCommunities = true
                user.showMeetings = true
                user.notificationsEnabled = true
                users.updated++
            } else {
                users.unchanged++
            }
        }
        manifest.communities.forEach { desired ->
            val community = resolved.communities[desired.key]
            if (community == null) {
                communityRepository.save(Community(desired.name, desired.description, desired.imageUrl, demoCatalogKey = desired.key.value))
                communities.created++
            } else if (
                community.name != desired.name ||
                community.description != desired.description ||
                community.imageUrl != desired.imageUrl
            ) {
                community.name = desired.name
                community.description = desired.description
                community.imageUrl = desired.imageUrl
                communities.updated++
            } else {
                communities.unchanged++
            }
        }
        manifest.meetings.forEach { desired ->
            val compiled = compiledMeetings.getValue(desired.key)
            val meeting = resolved.meetings[desired.key]
            if (meeting == null) {
                meetingRepository.save(
                    Meeting(
                        desired.title,
                        desired.description,
                        desired.imageUrl,
                        compiled.time,
                        compiled.date,
                        desired.address,
                        desired.latitude,
                        desired.longitude,
                        desired.capacity,
                        desired.status,
                        source = desired.source,
                        externalUrl = desired.externalUrl,
                        isOnline = desired.online,
                        endsAt = compiled.endsAt,
                        demoCatalogKey = desired.key.value,
                    ),
                )
                meetings.created++
            } else if (meetingChanged(meeting, desired, compiled)) {
                meeting.title = desired.title
                meeting.description = desired.description
                meeting.imageUrl = desired.imageUrl
                meeting.time = compiled.time
                meeting.date = compiled.date
                meeting.address = desired.address
                meeting.latitude = desired.latitude
                meeting.longitude = desired.longitude
                meeting.capacity = desired.capacity
                meeting.status = desired.status
                meeting.source = desired.source
                meeting.sourceExternalId = null
                meeting.externalUrl = desired.externalUrl
                meeting.isOnline = desired.online
                meeting.ingestedAt = null
                meeting.dedupHash = null
                meeting.endsAt = compiled.endsAt
                meetings.updated++
            } else {
                meetings.unchanged++
            }
        }
        manifest.adBlocks.forEach { desired ->
            val ad = resolved.adBlocks[desired.key]
            if (ad == null) {
                adBlockRepository.save(
                    AdBlock().apply {
                        demoCatalogKey = desired.key.value
                        type = desired.type
                        isActive = desired.active
                        title = desired.title
                        description = desired.description
                        actionText = desired.actionText
                        actionUrl = desired.actionUrl
                    },
                )
                ads.created++
            } else if (
                ad.type != desired.type ||
                ad.isActive != desired.active ||
                ad.title != desired.title ||
                ad.description != desired.description ||
                ad.actionText != desired.actionText ||
                ad.actionUrl != desired.actionUrl
            ) {
                ad.type = desired.type
                ad.isActive = desired.active
                ad.title = desired.title
                ad.description = desired.description
                ad.actionText = desired.actionText
                ad.actionUrl = desired.actionUrl
                ads.updated++
            } else {
                ads.unchanged++
            }
        }
        entityManager.flush()
        return RootSummary(tags.result(), users.result(), communities.result(), meetings.result(), ads.result())
    }

    private fun reconcileRelationships(resolved: Resolved): RelationshipSummary {
        val users = manifest.users.associate { it.key to (resolved.users[it.key] ?: userRepository.findAllByDemoCatalogKeyIn(listOf(it.key.value)).single()) }
        val communities = manifest.communities.associate { it.key to (resolved.communities[it.key] ?: communityRepository.findAllByDemoCatalogKeyIn(listOf(it.key.value)).single()) }
        val meetings = manifest.meetings.associate { it.key to (resolved.meetings[it.key] ?: meetingRepository.findAllByDemoCatalogKeyIn(listOf(it.key.value)).single()) }
        val ads = manifest.adBlocks.associate { it.key to (resolved.adBlocks[it.key] ?: adBlockRepository.findAllByDemoCatalogKeyIn(listOf(it.key.value)).single()) }
        val tags = resolved.tags
        val userInterests = RelationshipCounter()
        val communityTags = RelationshipCounter()
        val communitySubscribers = RelationshipCounter()
        val meetingTags = RelationshipCounter()
        val meetingParticipants = RelationshipCounter()
        val meetingPersonHosts = RelationshipCounter()
        val meetingCommunityHosts = RelationshipCounter()
        val adCommunities = RelationshipCounter()
        val adUsers = RelationshipCounter()
        manifest.users.forEach { desired ->
            userInterests.add(reconcile(users.getValue(desired.key).interests, desired.interests.map(tags::getValue).toSet(), preserveUnowned = true))
        }
        manifest.communities.forEach { desired ->
            val community = communities.getValue(desired.key)
            communityTags.add(reconcile(community.tags, desired.tags.map(tags::getValue).toSet(), preserveUnowned = true))
            communitySubscribers.add(reconcile(community.subscribers, desired.subscribers.map(users::getValue).toSet(), preserveUnowned = true))
        }
        manifest.meetings.forEach { desired ->
            val meeting = meetings.getValue(desired.key)
            meetingTags.add(reconcile(meeting.tags, desired.tags.map(tags::getValue).toSet(), preserveUnowned = true))
            meetingParticipants.add(reconcile(meeting.participants, desired.participants.map(users::getValue).toSet(), preserveUnowned = true))
            meetingPersonHosts.add(reconcileHost(meeting.personHost, users.getValue(desired.personHost)) { meeting.personHost = it })
            meetingCommunityHosts.add(reconcileHost(meeting.communityHost, communities.getValue(desired.communityHost)) { meeting.communityHost = it })
        }
        manifest.adBlocks.forEach { desired ->
            val ad = ads.getValue(desired.key)
            adCommunities.add(reconcile(ad.communities, desired.communities.map(communities::getValue).toSet(), preserveUnowned = true))
            adUsers.add(reconcile(ad.users, desired.users.map(users::getValue).toSet(), preserveUnowned = true))
        }
        return RelationshipSummary(
            userInterests.result(),
            communityTags.result(),
            communitySubscribers.result(),
            meetingTags.result(),
            meetingParticipants.result(),
            meetingPersonHosts.result(),
            meetingCommunityHosts.result(),
            adCommunities.result(),
            adUsers.result(),
        )
    }

    private fun <T : Any> reconcile(current: MutableSet<T>, desired: Set<T>, preserveUnowned: Boolean): RelationshipCounts {
        val currentById = current.associateBy { entityId(it) }
        val desiredById = desired.associateBy { entityId(it) }
        val added = desiredById.keys.count { it !in currentById }
        val unchanged = desiredById.keys.count { it in currentById }
        val removed = current.filter { entityId(it) !in desiredById && (!preserveUnowned || isOwned(it)) }
        current.removeAll(removed.toSet())
        current.addAll(desired)
        return RelationshipCounts(added, removed.size, unchanged)
    }

    private fun <T : Any> reconcileHost(current: T?, desired: T, setter: (T) -> Unit): RelationshipCounts {
        if (current == null) {
            setter(desired)
            return RelationshipCounts(added = 1)
        }
        if (entityId(current) == entityId(desired)) return RelationshipCounts(unchanged = 1)
        if (!isOwned(current)) return RelationshipCounts(unchanged = 1)
        setter(desired)
        return RelationshipCounts(added = 1, removed = 1)
    }

    private fun entityId(value: Any): Long? = when (value) {
        is Tag -> value.id
        is User -> value.id
        is Community -> value.id
        is Meeting -> value.id
        is AdBlock -> value.id
        else -> error("Unsupported relationship entity")
    }

    private fun isOwned(value: Any): Boolean = when (value) {
        is Tag -> value.demoCatalogKey != null
        is User -> value.demoCatalogKey != null
        is Community -> value.demoCatalogKey != null
        is Meeting -> value.demoCatalogKey != null
        is AdBlock -> value.demoCatalogKey != null
        else -> false
    }

    private fun userChanged(user: User, desired: ManifestUser): Boolean =
        user.name != desired.name ||
            user.surname != desired.surname ||
            user.email != desired.email ||
            user.city != desired.city ||
            user.avatarUrl != desired.avatarUrl ||
            user.bio != desired.bio ||
            !user.showCommunities ||
            !user.showMeetings ||
            !user.notificationsEnabled

    private fun meetingChanged(meeting: Meeting, desired: ManifestMeeting, compiled: CompiledMeeting): Boolean =
        meeting.title != desired.title ||
            meeting.description != desired.description ||
            meeting.imageUrl != desired.imageUrl ||
            meeting.time != compiled.time ||
            meeting.date != compiled.date ||
            meeting.address != desired.address ||
            meeting.latitude != desired.latitude ||
            meeting.longitude != desired.longitude ||
            meeting.capacity != desired.capacity ||
            meeting.status != desired.status ||
            meeting.source != EventSource.MANUAL ||
            meeting.sourceExternalId != null ||
            meeting.externalUrl != desired.externalUrl ||
            meeting.isOnline != desired.online ||
            meeting.ingestedAt != null ||
            meeting.dedupHash != null ||
            meeting.endsAt != compiled.endsAt

    private fun count(sql: String, vararg args: Any?): Long =
        jdbcTemplate.queryForObject(sql, Long::class.java, *args) ?: 0L

    private class RootCounter {
        var created = 0
        var updated = 0
        var unchanged = 0
        fun result() = RootCounts(created, updated, unchanged)
    }

    private class RelationshipCounter {
        var added = 0
        var removed = 0
        var unchanged = 0
        fun add(value: RelationshipCounts) {
            added += value.added
            removed += value.removed
            unchanged += value.unchanged
        }
        fun result() = RelationshipCounts(added, removed, unchanged)
    }
}
