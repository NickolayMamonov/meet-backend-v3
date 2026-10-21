package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.User
import dev.whysoezzy.meet.service.MeetingService
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.beans.factory.annotation.Autowired
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TimepadHiddenMeetingLeavePostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var meetingService: MeetingService

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `participants may leave expired and revoked meetings while hidden reads and join remain not found`() {
        val expiredUser = users.save(User("Expired", "Participant", "+15550000101"))
        val revokedUser = users.save(User("Revoked", "Participant", "+15550000102"))
        val now = System.currentTimeMillis()
        val expired = meetings.save(hiddenMeeting("expired", expiredUser, now + 1, now - 1))
        val revoked = meetings.save(hiddenMeeting("revoked", revokedUser, now + 2, null))
        meetings.flush()

        listOf(expired to expiredUser, revoked to revokedUser).forEach { (meeting, participant) ->
            val meetingId = requireNotNull(meeting.id)
            val userId = requireNotNull(participant.id)

            assertThrows<NotFoundException> { meetingService.getMeetingById(meetingId, null) }
            assertThrows<NotFoundException> { meetingService.getMeetingParticipants(meetingId) }
            assertThrows<NotFoundException> { meetingService.joinMeeting(meetingId, userId) }
            assertTrue(meetings.isUserParticipant(meetingId, userId))

            meetingService.leaveMeeting(meetingId, userId)

            assertFalse(meetings.isUserParticipant(meetingId, userId))
        }
    }

    private fun hiddenMeeting(
        externalId: String,
        participant: User,
        startsAt: Long,
        eligibleUntil: Long?,
    ) = Meeting(
        title = "Hidden Timepad $externalId",
        description = "Visibility fixture",
        imageUrl = "",
        time = startsAt,
        date = "01.01.2027",
        address = "ул. Пример, 1",
        latitude = 55.75,
        longitude = 37.61,
        source = EventSource.TIMEPAD,
        sourceExternalId = externalId,
        participants = mutableSetOf(participant),
        timepadEligibleUntilMs = eligibleUntil,
    )
}
