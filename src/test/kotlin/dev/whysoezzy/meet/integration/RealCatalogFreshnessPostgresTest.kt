package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.MeetingStatus
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.data.domain.PageRequest
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.sql.Timestamp
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RealCatalogFreshnessPostgresTest : IntegrationTestSupport() {
    private val invitation = Instant.parse("2026-09-26T00:00:00Z")
    private val cutoff = Instant.parse("2026-09-27T00:00:00Z")

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `discovery and participation use invitation and cutoff boundaries`() {
        val fixture = fixture()
        installState(fixture)

        val before = invitation.minusMillis(1).toEpochMilli()
        val atInvitation = invitation.toEpochMilli()
        val atCutoff = cutoff.toEpochMilli()

        assertTrue(meetings.findDiscoveryMeetings(MeetingStatus.ACTIVE, before, PageRequest.of(0, 20)).isEmpty())
        assertTrue(communities.findDiscoveryCommunities(before, PageRequest.of(0, 20)).isEmpty())
        assertFalse(meetings.isFreshForParticipation(fixture.meeting.id!!, before))
        assertFalse(communities.isFreshForParticipation(fixture.community.id!!, before))

        assertEquals(1, meetings.findDiscoveryMeetings(MeetingStatus.ACTIVE, atInvitation, PageRequest.of(0, 20)).size)
        assertEquals(1, communities.findDiscoveryCommunities(atInvitation, PageRequest.of(0, 20)).size)
        assertTrue(meetings.isFreshForParticipation(fixture.meeting.id!!, atInvitation))
        assertTrue(communities.isFreshForParticipation(fixture.community.id!!, atInvitation))

        assertTrue(meetings.findDiscoveryMeetings(MeetingStatus.ACTIVE, atCutoff, PageRequest.of(0, 20)).isEmpty())
        assertTrue(communities.findDiscoveryCommunities(atCutoff, PageRequest.of(0, 20)).isEmpty())
        assertFalse(meetings.isFreshForParticipation(fixture.meeting.id!!, atCutoff))
        assertFalse(communities.isFreshForParticipation(fixture.community.id!!, atCutoff))
    }

    @Test
    fun `embedded discovery query applies its limit after freshness filtering`() {
        val fixture = fixture()
        installState(fixture)
        val now = invitation.toEpochMilli()

        repeat(7) { index ->
            jdbcTemplate.update(
                """
                INSERT INTO meetings (
                    title, description, image_url, time, date, address, latitude, longitude,
                    capacity, status, community_host_id, source, is_online, real_catalog_key,
                    real_catalog_item_key, real_catalog_active, real_catalog_fingerprint
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'ACTIVE', ?, 'MANUAL', false, ?, ?, ?, ?)
                """.trimIndent(),
                "Sibling $index",
                "Synthetic sibling",
                "https://example.test/sibling-$index.png",
                Instant.parse("2026-10-02T10:00:00Z").toEpochMilli() + index,
                "02.10.2026",
                "Online",
                0.0,
                0.0,
                10,
                fixture.community.id,
                "closed-beta-real:sibling-$index",
                if (index < 2) true else false,
                "b".repeat(64),
            )
        }

        val siblings = meetings.findDiscoverySiblings(fixture.community.id!!, now)
        assertEquals(3, siblings.size)
        assertTrue(siblings.all { it.realCatalogActive == true || it.realCatalogKey == null })
    }

    private fun installState(fixture: ApiFixture) {
        val manifestBytes = "freshness-fixture".toByteArray(StandardCharsets.UTF_8)
        val digest = sha256(manifestBytes)
        jdbcTemplate.update(
            """
            INSERT INTO real_catalog_revisions (
                digest, catalog_key, revision_label, schema_version, intent, manifest_bytes,
                resolved_snapshot, invitation_at, window_end_at, review_at, next_review_at,
                discoverable_until, content_approval_ref, mutation_approval_ref,
                recovery_point_ref, applied_at, generation
            ) VALUES (?, 'closed-beta-real', 'freshness-fixture', 'v1', 'INITIAL', ?,
                '{"communities":[],"meetings":[]}', ?, ?, ?, ?, ?, 'content', 'mutation',
                'recovery', ?, 1)
            """.trimIndent(),
            digest,
            manifestBytes,
            Timestamp.from(invitation),
            Timestamp.from(Instant.parse("2026-10-26T00:00:00Z")),
            Timestamp.from(Instant.parse("2026-09-25T12:00:00Z")),
            Timestamp.from(Instant.parse("2026-10-02T12:00:00Z")),
            Timestamp.from(cutoff),
            Timestamp.from(invitation),
        )
        jdbcTemplate.update(
            """
            INSERT INTO real_catalog_state (
                catalog_key, current_digest, generation, current_intent, invitation_at,
                window_end_at, review_at, next_review_at, discoverable_until, owner_role
            ) VALUES ('closed-beta-real', ?, 1, 'INITIAL', ?, ?, ?, ?, ?, 'project-operator')
            """.trimIndent(),
            digest,
            Timestamp.from(invitation),
            Timestamp.from(Instant.parse("2026-10-26T00:00:00Z")),
            Timestamp.from(Instant.parse("2026-09-25T12:00:00Z")),
            Timestamp.from(Instant.parse("2026-10-02T12:00:00Z")),
            Timestamp.from(cutoff),
        )
        jdbcTemplate.update(
            """
            UPDATE communities
            SET real_catalog_key = 'closed-beta-real',
                real_catalog_item_key = 'community-one',
                real_catalog_active = true,
                real_catalog_fingerprint = ?
            WHERE id = ?
            """.trimIndent(),
            "a".repeat(64),
            fixture.community.id,
        )
        jdbcTemplate.update(
            """
            UPDATE meetings
            SET time = ?, ends_at = ?, real_catalog_key = 'closed-beta-real',
                real_catalog_item_key = 'meeting-one', real_catalog_active = true,
                real_catalog_fingerprint = ?, source = 'MANUAL',
                source_external_id = 'closed-beta-real:meeting-one'
            WHERE id = ?
            """.trimIndent(),
            Instant.parse("2026-10-02T10:00:00Z").toEpochMilli(),
            Instant.parse("2026-10-02T12:00:00Z").toEpochMilli(),
            "a".repeat(64),
            fixture.meeting.id,
        )
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
}
