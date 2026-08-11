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
    fun `discovery applies active and inclusive effective-end visibility before paging`() {
        val now = 1_700_000_000_000L
        val hidden = meetings.save(meeting("hidden", now + 1, endsAt = now - 1))
        val equal = meetings.save(meeting("equal", now + 2, endsAt = now))
        val fallback = meetings.save(meeting("fallback", now))
        val later = meetings.save(meeting("later", now + 3, endsAt = now + 1))
        val cancelled = meetings.save(
            meeting("cancelled", now + 4, endsAt = now + 1).also {
                it.status = MeetingStatus.CANCELLED
            },
        )
        meetings.flush()

        val result = meetings.findDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            now,
            PageRequest.of(0, 2),
        )

        assertEquals(listOf(fallback.id, equal.id), result.map { it.id })
        assertTrue(hidden.id !in result.map { it.id })
        assertTrue(later.id !in result.map { it.id })
        assertTrue(cancelled.id !in result.map { it.id })
        assertEquals(
            listOf(fallback.id, equal.id, later.id),
            meetings.findDiscoveryMeetings(
                MeetingStatus.ACTIVE,
                now,
                PageRequest.of(0, 20),
            ).map { it.id },
        )
    }

    @Test
    fun `tag search and popularity discovery queries share visibility and stable ties`() {
        val now = 1_700_000_000_000L
        val tag = tags.save(Tag("Kotlin"))
        val participant = users.save(User("Participant", "User", "+15550000001"))
        val first = meetings.save(
            meeting("Kotlin first", now + 1).also {
                it.tags.add(tag)
                it.participants.add(participant)
            },
        )
        val completed = meetings.save(
            meeting("Kotlin completed", now + 2, endsAt = now - 1).also {
                it.tags.add(tag)
                it.participants.add(participant)
            },
        )
        val second = meetings.save(
            meeting("Kotlin second", now + 1).also { it.tags.add(tag) },
        )
        meetings.flush()

        assertEquals(
            listOf(first.id, second.id),
            meetings.findDiscoveryMeetingsByTag(
                tag.id!!,
                MeetingStatus.ACTIVE,
                now,
                PageRequest.of(0, 10),
            ).map { it.id },
        )
        assertEquals(
            listOf(first.id, second.id),
            meetings.searchDiscoveryMeetings("kotlin", MeetingStatus.ACTIVE, now).map { it.id },
        )
        assertEquals(
            listOf(first.id, second.id),
            meetings.findPopularDiscoveryMeetings(
                MeetingStatus.ACTIVE,
                now,
                PageRequest.of(0, 10),
            ).map { it.id },
        )
        assertTrue(completed.id !in meetings.findPopularDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            now,
            PageRequest.of(0, 10),
        ).map { it.id })
    }

    private fun meeting(title: String, time: Long, endsAt: Long? = null) = Meeting(
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
