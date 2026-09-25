package dev.whysoezzy.meet.catalog

import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import org.springframework.stereotype.Component
import java.time.Clock

@Component
class RealCatalogManifestValidator(
    private val clock: Clock = Clock.systemUTC(),
) {
    fun validate(manifest: RealCatalogManifest, bytes: ByteArray): String {
        require(bytes.size <= MAX_BYTES) { "Real catalog manifest is too large" }
        require(StandardCharsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString().toByteArray(StandardCharsets.UTF_8).contentEquals(bytes)) {
            "Real catalog manifest must be valid UTF-8"
        }
        require(manifest.schemaVersion == SCHEMA_VERSION) { "Unsupported real catalog schema version" }
        require(manifest.catalogKey == CATALOG_KEY) { "Invalid real catalog key" }
        key(manifest.revisionLabel, "revision label")
        key(manifest.ownerRole, "owner role", 80)
        require(manifest.invitationAt < manifest.windowEndAt) { "Invitation window must be positive" }
        if (manifest.intent == RealCatalogIntent.INITIAL || manifest.intent == RealCatalogIntent.NEW_WINDOW) {
            require(manifest.windowEndAt == manifest.invitationAt.plus(Duration.ofDays(30))) {
                "Invitation window must be exactly 30 elapsed days"
            }
        }
        require(!manifest.reviewAt.isAfter(clock.instant())) { "Review must not be in the future" }
        require(manifest.nextReviewAt == manifest.reviewAt.plus(Duration.ofDays(7))) { "Next review must be seven elapsed days after review" }
        ZoneId.of(manifest.invitationZone)
        require(manifest.communities.size <= MAX_COMMUNITIES) { "Too many communities" }
        require(manifest.meetings.size <= MAX_MEETINGS) { "Too many meetings" }
        requireUnique(manifest.communities.map { it.logicalKey }, "community")
        requireUnique(manifest.meetings.map { it.logicalKey }, "meeting")
        require(manifest.intent != RealCatalogIntent.INITIAL || manifest.predecessorDigest == null) {
            "Initial catalog must not have a predecessor"
        }
        manifest.predecessorDigest?.let {
            require(it.matches(Regex("^[0-9a-f]{64}$"))) { "Invalid predecessor digest" }
        }
        manifest.communities.forEach(::validateCommunity)
        val communityKeys = manifest.communities.map { it.logicalKey }.toSet()
        manifest.meetings.forEach {
            validateMeeting(it)
            key(it.communityKey, "meeting community key")
            if (manifest.intent != RealCatalogIntent.CORRECT) {
                require(it.communityKey in communityKeys) { "Meeting references an unknown community" }
            }
        }
        if (manifest.intent != RealCatalogIntent.CORRECT) {
            require(manifest.communities.any { it.membership == RealCatalogMembership.ACTIVE }) {
                "Activation requires an active community"
            }
            require(manifest.meetings.any { it.membership == RealCatalogMembership.ACTIVE }) {
                "Activation requires an active meeting"
            }
            require(manifest.meetings.filter { it.membership == RealCatalogMembership.ACTIVE }
                .all { it.startAt.isAfter(manifest.windowEndAt) }) {
                "Active meetings must start after the invitation window"
            }
        }
        return sha256(bytes)
    }

    private fun validateCommunity(item: RealCatalogCommunity) {
        key(item.logicalKey, "community logical key")
        require(item.name.isNotBlank() && item.name.length <= 255) { "Invalid community name" }
        require(item.description.isNotBlank()) { "Invalid community description" }
        validateUrl(item.imageUrl, "community image")
        validateTags(item.tags)
        validateSource(item.source)
        validateProvenance(item.provenance)
    }

    private fun validateMeeting(item: RealCatalogMeeting) {
        key(item.logicalKey, "meeting logical key")
        require(item.title.isNotBlank() && item.title.length <= 300) { "Invalid meeting title" }
        require(item.description.isNotBlank()) { "Invalid meeting description" }
        validateUrl(item.imageUrl, "meeting image")
        require(item.endAt == null || item.endAt.isAfter(item.startAt)) { "Meeting end must be after start" }
        ZoneId.of(item.sourceZone)
        require(item.dateLabel.isNotBlank() && item.dateLabel.length <= 50) { "Invalid meeting date label" }
        require(item.address.isNotBlank()) { "Invalid meeting address" }
        require(item.latitude in -90.0..90.0 && item.longitude in -180.0..180.0) { "Invalid meeting coordinates" }
        require(item.capacity > 0) { "Meeting capacity must be positive" }
        validateTags(item.tags)
        item.externalUrl?.let { validateUrl(it, "meeting external URL") }
        validateSource(item.source)
        validateProvenance(item.provenance)
    }

    private fun validateProvenance(provenance: RealCatalogFieldProvenance) {
        listOf(provenance.title, provenance.description, provenance.image, provenance.organizer, provenance.schedule, provenance.location)
            .forEach { requireNotNull(it) { "Every retained field requires provenance" }; validateSource(it) }
    }

    private fun validateSource(source: RealCatalogSource) {
        validateUrl(source.publicUrl, "source URL")
        require(source.basis.isNotBlank() && source.basis.length <= 160) { "Invalid rights basis" }
        require(source.evidenceRef.matches(OPAQUE_REF)) { "Invalid evidence reference" }
        require(source.attribution.isNotBlank() && source.attribution.length <= 160) {
            "Invalid attribution"
        }
        require(source.retentionPermission.isNotBlank() && source.retentionPermission.length <= 160) {
            "Invalid retention permission"
        }
        source.discoveryUseCutoff?.let { require(!it.isBefore(source.checkedAt)) { "Invalid discovery cutoff" } }
    }

    private fun validateUrl(value: String, label: String) {
        val uri = runCatching { URI(value) }.getOrNull()
        require(uri?.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null) {
            "Invalid $label URL"
        }
        require(uri.fragment == null) { "Invalid $label URL" }
    }

    private fun validateTags(tags: List<String>) {
        require(tags.size <= 50 && tags.distinct().size == tags.size && tags.all { it.isNotBlank() && it.length <= 100 }) {
            "Invalid catalog tags"
        }
    }

    private fun key(value: String, label: String, maxLength: Int = 120) {
        require(value.length <= maxLength && value.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))) {
            "Invalid $label"
        }
    }

    private fun requireUnique(values: List<String>, label: String) {
        require(values.distinct().size == values.size) { "Duplicate $label logical key" }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    companion object {
        const val CATALOG_KEY = "closed-beta-real"
        const val SCHEMA_VERSION = "v1"
        const val MAX_BYTES = 1_048_576
        const val MAX_MEETINGS = 100
        const val MAX_COMMUNITIES = 50
        private val OPAQUE_REF = Regex("^[A-Za-z0-9._:/-]{1,160}$")
    }
}
