package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import dev.whysoezzy.meet.domain.entity.Tag
import dev.whysoezzy.meet.domain.entity.User
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.data.domain.PageRequest
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MeetingDiscoveryRepositoryPostgresTest : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `effective end keeps before equal and after boundaries plus null fallback`() {
        val now = 1_700_000_000_000L
        val before = meetings.save(meeting("before", time = now + 10_000, endsAt = now - 1))
        val equal = meetings.save(meeting("equal", time = now + 20_000, endsAt = now))
        val after = meetings.save(meeting("after", time = now + 30_000, endsAt = now + 1))
        val fallbackBefore = meetings.save(meeting("fallback-before", time = now - 1))
        val fallbackEqual = meetings.save(meeting("fallback-equal", time = now))
        val cancelled = meetings.save(
            meeting("cancelled", time = now + 40_000, endsAt = now + 1).also {
                it.status = MeetingStatus.CANCELLED
            },
        )
        meetings.flush()

        val result = meetings.findDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            now,
            PageRequest.of(0, 20),
        )

        assertEquals(
            listOf(fallbackEqual.id, equal.id, after.id),
            result.map { it.id },
        )
        assertTrue(cancelled.id !in result.map { it.id })
        assertTrue(before.id !in result.map { it.id })
        assertTrue(fallbackBefore.id !in result.map { it.id })
    }

    @Test
    fun `tag and search discovery filter before database pagination`() {
        val now = 1_700_000_000_000L
        val kotlin = tags.save(Tag("Kotlin"))
        val eligibleOne = meetings.save(
            meeting("Kotlin one", now + 1).also { it.tags.add(kotlin) },
        )
        val completed = meetings.save(
            meeting("Kotlin completed", now - 1, endsAt = now - 1).also { it.tags.add(kotlin) },
        )
        val eligibleTwo = meetings.save(
            meeting("Kotlin two", now + 2).also { it.tags.add(kotlin) },
        )
        meetings.flush()

        assertEquals(
            listOf(eligibleOne.id, eligibleTwo.id),
            meetings.findDiscoveryMeetingsByTag(
                kotlin.id!!,
                MeetingStatus.ACTIVE,
                now,
                PageRequest.of(0, 2),
            ).map { it.id },
        )
        assertEquals(
            listOf(eligibleOne.id, eligibleTwo.id),
            meetings.searchDiscoveryMeetings("kotlin", MeetingStatus.ACTIVE, now).map { it.id },
        )
        assertTrue(completed.id !in meetings.searchDiscoveryMeetings("kotlin", MeetingStatus.ACTIVE, now).map { it.id })
    }

    @Test
    fun `popular filters completed rows before ranking and applies deterministic ties`() {
        val now = 1_700_000_000_000L
        val participant = users.save(User("Participant", "One", "+15550000001"))
        val completed = meetings.save(
            meeting("completed", now + 1, endsAt = now - 1).also {
                it.participants.add(participant)
            },
        )
        val tieLate = meetings.save(meeting("tie-late", now + 20))
        val tieEarly = meetings.save(meeting("tie-early", now + 10))
        meetings.flush()

        val result = meetings.findPopularDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            now,
            PageRequest.of(0, 2),
        )

        assertEquals(listOf(tieEarly.id, tieLate.id), result.map { it.id })
        assertTrue(completed.id !in result.map { it.id })
    }

    @Test
    fun `detail and participant history remain available for completed meetings`() {
        val participant = users.save(User("History", "User", "+15550000002"))
        val completed = meetings.save(
            meeting("historical", 1_600_000_000_000).also {
                it.participants.add(participant)
            },
        )
        meetings.flush()

        assertEquals(completed.id, meetings.findById(completed.id!!).orElseThrow().id)
        assertEquals(listOf(completed.id), meetings.findByParticipantId(participant.id!!).map { it.id })
    }

    @Test
    fun `representative discovery predicate produces explain evidence`() {
        val plan = jdbcTemplate.query(
            """
            EXPLAIN (ANALYZE, BUFFERS)
            SELECT id
            FROM meetings
            WHERE status = 'ACTIVE'
              AND COALESCE(ends_at, time) >= 1700000000000
            ORDER BY time ASC, id ASC
            LIMIT 20
            """.trimIndent(),
        ) { rs, _ -> rs.getString(1) }

        assertTrue(plan.isNotEmpty())
        assertTrue(plan.any { it.contains("Scan") || it.contains("scan") })
    }

    private fun meeting(
        title: String,
        time: Long,
        endsAt: Long? = null,
    ) = Meeting(
        title = title,
        description = "Repository fixture",
        imageUrl = "",
        time = time,
        date = "01.01.2026",
        address = "Online",
        latitude = 0.0,
        longitude = 0.0,
        endsAt = endsAt,
    )
}
