package dev.whysoezzy.meet.service.push

import java.time.Instant

enum class ReminderEligibilityReason {
    USER_UNAVAILABLE,
    OPTED_OUT,
    LEFT_MEETING,
    MEETING_UNAVAILABLE,
    START_CHANGED,
    STARTED,
    INSTALLATION_UNAVAILABLE,
    INSTALLATION_STALE,
    DEADLINE_PASSED,
}

data class ReminderEligibilityInput(
    val userAvailable: Boolean,
    val optedIn: Boolean,
    val joinedMeeting: Boolean,
    val meetingAvailable: Boolean,
    val expectedStart: Instant,
    val actualStart: Instant?,
    val expectedStartVersion: Long,
    val actualStartVersion: Long?,
    val installationAvailable: Boolean,
    val installationFresh: Boolean,
    val now: Instant,
    val deadline: Instant,
)

object ReminderEligibility {
    fun reason(input: ReminderEligibilityInput): ReminderEligibilityReason? = when {
        !input.userAvailable -> ReminderEligibilityReason.USER_UNAVAILABLE
        !input.optedIn -> ReminderEligibilityReason.OPTED_OUT
        !input.joinedMeeting -> ReminderEligibilityReason.LEFT_MEETING
        !input.meetingAvailable -> ReminderEligibilityReason.MEETING_UNAVAILABLE
        input.actualStart == null || input.actualStart != input.expectedStart ||
            input.actualStartVersion != input.expectedStartVersion ->
            ReminderEligibilityReason.START_CHANGED
        !input.actualStart.isAfter(input.now) -> ReminderEligibilityReason.STARTED
        !input.installationAvailable -> ReminderEligibilityReason.INSTALLATION_UNAVAILABLE
        !input.installationFresh -> ReminderEligibilityReason.INSTALLATION_STALE
        input.now.isAfter(input.deadline) -> ReminderEligibilityReason.DEADLINE_PASSED
        else -> null
    }

    fun eligible(input: ReminderEligibilityInput): Boolean = reason(input) == null
}
