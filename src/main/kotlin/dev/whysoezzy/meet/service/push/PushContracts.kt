package dev.whysoezzy.meet.service.push

import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

typealias Fid = PushFid
typealias ReminderMessage = PushReminderMessage
typealias PushSendResult = PushDeliveryResult

const val MAX_FID_BYTES = 1_024

fun parseFid(value: String): Fid {
    require(value.isNotEmpty()) { "FID is required" }
    require('\u0000' !in value) { "FID contains an invalid character" }
    val byteCount = try {
        val encoder = StandardCharsets.UTF_8.newEncoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        encoder.encode(CharBuffer.wrap(value)).remaining()
    } catch (_: CharacterCodingException) {
        throw IllegalArgumentException("FID is not valid UTF-8")
    }
    require(byteCount in 1..MAX_FID_BYTES) { "FID is too long" }
    return PushFid(value)
}

object ReminderMessageFactory {
    fun create(
        eventId: UUID,
        meetingId: Long,
        offset: ReminderOffset,
        issuedAt: Instant,
    ): ReminderMessage =
        PushReminderMessage.meetingReminder(
            eventId = eventId,
            meetingId = meetingId,
            reminderOffsetMinutes = offset.minutes,
            issuedAt = issuedAt.truncatedTo(ChronoUnit.MILLIS),
        )
}

enum class ReminderOffset(val minutes: Int) {
    ONE_HOUR(60),
    ONE_DAY(1_440);

    companion object {
        fun fromMinutes(minutes: Int): ReminderOffset =
            entries.firstOrNull { it.minutes == minutes }
                ?: throw IllegalArgumentException("Unsupported reminder offset")
    }
}

enum class InstallationStatus {
    ACTIVE,
    UNREGISTERED,
    INVALID,
    EXPIRED,
    TRANSFERRED,
    ACCOUNT_DELETED,
}

enum class ReminderClaimStatus {
    PENDING,
    SENT,
    FAILED,
    SKIPPED,
    NO_TARGET,
}

enum class ReminderTargetReason {
    TRANSIENT,
    PROVIDER_UNAVAILABLE,
    ACCEPTED,
    UNREGISTERED,
    ATTEMPTS_EXHAUSTED,
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
