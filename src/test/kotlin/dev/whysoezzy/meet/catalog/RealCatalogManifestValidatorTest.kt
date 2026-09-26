package dev.whysoezzy.meet.catalog

import dev.whysoezzy.meet.domain.entity.MeetingStatus
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.assertEquals

class RealCatalogManifestValidatorTest {
    private val now = Instant.parse("2026-09-25T12:00:00Z")
    private val validator = RealCatalogManifestValidator(Clock.fixed(now, ZoneOffset.UTC))

    @Test
    fun `validates exact digest and rights reviewed future catalog`() {
        val bytes = "synthetic".toByteArray()
        val digest = validator.validate(manifest(), bytes)
        assertEquals(64, digest.length)
        assertEquals(digest, validator.validate(manifest(), bytes))
    }

    @Test
    fun `rejects credentials and missing retained field provenance`() {
        assertThrows<IllegalArgumentException> {
            validator.validate(
                manifest(
                    source = source(publicUrl = "https://user:password@example.test/source"),
                ),
                "{}".toByteArray(),
            )
        }
        assertThrows<IllegalArgumentException> {
            validator.validate(
                manifest(provenance = RealCatalogFieldProvenance()),
                "{}".toByteArray(),
            )
        }
    }

    @Test
    fun `correction may be empty while activation cannot`() {
        val correction = manifest(
            intent = RealCatalogIntent.CORRECT,
            communities = emptyList(),
            meetings = emptyList(),
        )
        validator.validate(correction, "{}".toByteArray())
        assertThrows<IllegalArgumentException> {
            validator.validate(
                manifest(communities = emptyList(), meetings = emptyList()),
                "{}".toByteArray(),
            )
        }
    }

    @Test
    fun `rejects a date label that does not match the source zone`() {
        assertThrows<IllegalArgumentException> {
            validator.validate(
                manifest(
                    meetings = listOf(
                        manifest().meetings.single().copy(dateLabel = "25.10.2026"),
                    ),
                ),
                "{}".toByteArray(),
            )
        }
    }

    @Test
    fun `rejects sub-millisecond instants`() {
        assertThrows<IllegalArgumentException> {
            validator.validate(
                manifest(
                    meetings = listOf(
                        manifest().meetings.single().copy(
                            startAt = now.plus(Duration.ofDays(31)).plusNanos(1),
                        ),
                    ),
                ),
                "{}".toByteArray(),
            )
        }
    }

    private fun manifest(
        intent: RealCatalogIntent = RealCatalogIntent.INITIAL,
        communities: List<RealCatalogCommunity> = listOf(
            RealCatalogCommunity(
                logicalKey = "community-one",
                membership = RealCatalogMembership.ACTIVE,
                name = "Synthetic community",
                description = "Synthetic fixture",
                imageUrl = "https://example.test/community.png",
                tags = listOf("beta"),
                source = source(),
                provenance = RealCatalogFieldProvenance(
                    title = source(),
                    description = source(),
                    image = source(),
                    organizer = source(),
                    schedule = source(),
                    location = source(),
                ),
            ),
        ),
        meetings: List<RealCatalogMeeting> = listOf(
            RealCatalogMeeting(
                logicalKey = "meeting-one",
                membership = RealCatalogMembership.ACTIVE,
                title = "Synthetic meeting",
                description = "Synthetic fixture",
                imageUrl = "https://example.test/meeting.png",
                startAt = now.plus(Duration.ofDays(31)),
                endAt = now.plus(Duration.ofDays(31)).plus(Duration.ofHours(2)),
                sourceZone = "UTC",
                dateLabel = "26.10.2026",
                address = "Online",
                latitude = 0.0,
                longitude = 0.0,
                capacity = 10,
                isOnline = true,
                status = MeetingStatus.ACTIVE,
                tags = listOf("beta"),
                communityKey = "community-one",
                externalUrl = "https://example.test/event",
                source = source(),
                provenance = RealCatalogFieldProvenance(
                    title = source(),
                    description = source(),
                    image = source(),
                    organizer = source(),
                    schedule = source(),
                    location = source(),
                ),
            ),
        ),
        source: RealCatalogSource = source(),
        provenance: RealCatalogFieldProvenance = RealCatalogFieldProvenance(
            title = source,
            description = source,
            image = source,
            organizer = source,
            schedule = source,
            location = source,
        ),
    ) = RealCatalogManifest(
        schemaVersion = "v1",
        catalogKey = "closed-beta-real",
        revisionLabel = "synthetic-v1",
        intent = intent,
        ownerRole = "project-operator",
        invitationAt = now.minus(Duration.ofDays(1)),
        invitationZone = "UTC",
        windowEndAt = now.minus(Duration.ofDays(1)).plus(Duration.ofDays(30)),
        reviewAt = now.minus(Duration.ofHours(1)),
        nextReviewAt = now.plus(Duration.ofDays(7)).minus(Duration.ofHours(1)),
        predecessorDigest = if (intent == RealCatalogIntent.INITIAL) null else "a".repeat(64),
        communities = communities.map { it.copy(provenance = provenance) },
        meetings = meetings.map { it.copy(provenance = provenance) },
    )

    companion object {
        fun source(publicUrl: String = "https://example.test/source") = RealCatalogSource(
            publicUrl = publicUrl,
            checkedAt = Instant.parse("2026-09-25T00:00:00Z"),
            basis = "synthetic fixture",
            evidenceRef = "fixture/source",
            attribution = "synthetic",
            retentionPermission = "fixture permission",
        )
    }
}
