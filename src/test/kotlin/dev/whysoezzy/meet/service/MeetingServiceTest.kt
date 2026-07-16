package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import java.util.Optional
import kotlin.test.assertEquals

class MeetingServiceTest {

    private val meetingRepository = mock(MeetingRepository::class.java)
    private val userRepository = mock(UserRepository::class.java)
    private val meetingService = MeetingService(meetingRepository, userRepository)

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

    private fun meeting(capacity: Int, participants: MutableSet<User>) = Meeting(
        title = "Full meeting",
        description = "Description",
        imageUrl = "",
        time = 0,
        date = "01.01.2026",
        address = "Address",
        latitude = 0.0,
        longitude = 0.0,
        capacity = capacity,
        participants = participants,
    )

    private fun user(phoneSuffix: String) = User(
        name = phoneSuffix,
        surname = "User",
        phone = "+1000000$phoneSuffix",
    )
}
