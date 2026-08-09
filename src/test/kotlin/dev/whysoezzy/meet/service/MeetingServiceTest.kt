package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.mockito.Mockito.verify
import org.springframework.data.domain.PageRequest
import java.util.Optional
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.assertEquals

class MeetingServiceTest {

    private val meetingRepository = mock(MeetingRepository::class.java)
    private val userRepository = mock(UserRepository::class.java)
    private val meetingService = MeetingService(
        meetingRepository,
        userRepository,
        Clock.fixed(Instant.EPOCH, ZoneOffset.UTC),
    )

    @Test
    fun `maps a full meeting domain failure to conflict`() {
        val existingParticipant = user("existing")
        val joiningUser = user("joining")
        val fullMeeting = meeting(capacity = 1, participants = mutableSetOf(existingParticipant))

        `when`(meetingRepository.findById(99L)).thenReturn(Optional.of(fullMeeting))
        `when`(userRepository.findById(42L)).thenReturn(Optional.of(joiningUser))
        `when`(meetingRepository.isUserParticipant(99L, 42L)).thenReturn(false)

        val exception = assertThrows<ConflictException> {
            meetingService.joinMeeting(99L, 42L)
        }

        assertEquals("Meeting is at full capacity", exception.message)
    }

    @Test
    fun `main composes bounded sections with database exclusions`() {
        val first = meeting(id = 1L, time = 1L)
        val popular = meeting(id = 2L, time = 2L)
        val later = meeting(id = 3L, time = 3L)
        `when`(
            meetingRepository.findDiscoveryMeetings(
                MeetingStatus.ACTIVE,
                0L,
                PageRequest.of(0, 1),
            ),
        ).thenReturn(listOf(first))
        `when`(
            meetingRepository.findPopularDiscoveryMeetingsExcluding(
                MeetingStatus.ACTIVE,
                0L,
                setOf(1L),
                PageRequest.of(0, 10),
            ),
        ).thenReturn(listOf(popular))
        `when`(
            meetingRepository.findDiscoveryMeetingsExcluding(
                MeetingStatus.ACTIVE,
                0L,
                setOf(1L, 2L),
                PageRequest.of(0, 10),
            ),
        ).thenReturn(listOf(later))

        val result = meetingService.getMainMeetings(null)

        assertEquals(listOf(1L, 2L, 3L), result.map { it.id })
        verify(meetingRepository).findDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            0L,
            PageRequest.of(0, 1),
        )
        verify(meetingRepository).findPopularDiscoveryMeetingsExcluding(
            MeetingStatus.ACTIVE,
            0L,
            setOf(1L),
            PageRequest.of(0, 10),
        )
        verify(meetingRepository).findDiscoveryMeetingsExcluding(
            MeetingStatus.ACTIVE,
            0L,
            setOf(1L, 2L),
            PageRequest.of(0, 10),
        )
    }

    @Test
    fun `all meetings delegates page and limit to discovery repository`() {
        val pageMeeting = meeting(id = 9L, time = 9L)
        `when`(
            meetingRepository.findDiscoveryMeetings(
                MeetingStatus.ACTIVE,
                0L,
                PageRequest.of(2, 7),
            ),
        ).thenReturn(listOf(pageMeeting))

        val result = meetingService.getAllMeetings(2, 7, null, null)

        assertEquals(listOf(9L), result.map { it.id })
        verify(meetingRepository).findDiscoveryMeetings(
            MeetingStatus.ACTIVE,
            0L,
            PageRequest.of(2, 7),
        )
    }

    private fun meeting(
        id: Long? = null,
        time: Long = 0L,
        capacity: Int = 100,
        participants: MutableSet<User> = mutableSetOf(),
    ) = Meeting(
        title = "Full meeting",
        description = "Description",
        imageUrl = "",
        time = time,
        date = "01.01.2026",
        address = "Address",
        latitude = 0.0,
        longitude = 0.0,
        capacity = capacity,
        participants = participants,
    ).also { it.id = id }

    private fun user(phoneSuffix: String) = User(
        name = phoneSuffix,
        surname = "User",
        phone = "+1000000$phoneSuffix",
    )
}
