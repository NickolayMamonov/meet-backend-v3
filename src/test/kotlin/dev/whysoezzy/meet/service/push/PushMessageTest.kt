package dev.whysoezzy.meet.service.push

import org.junit.jupiter.api.Test
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class PushMessageTest {
    @Test
    fun `message has the exact seven string data fields`() {
        val message = ReminderMessageFactory.create(
            UUID.fromString("123e4567-e89b-12d3-a456-426614174000"),
            42,
            ReminderOffset.ONE_HOUR,
            Instant.parse("2026-09-11T20:00:00.123456Z"),
        )

        assertEquals(
            listOf(
                "eventType",
                "schemaVersion",
                "eventId",
                "meetingId",
                "reminderOffsetMinutes",
                "issuedAt",
                "destination",
            ),
            message.data.keys.toList(),
        )
        assertEquals("123e4567-e89b-12d3-a456-426614174000", message.data["eventId"])
        assertEquals("2026-09-11T20:00:00.123Z", message.data["issuedAt"])
    }

    @Test
    fun `fid is opaque and bounded by utf8 bytes`() {
        assertFalse(parseFid("opaque").toString().contains("opaque"))
        assertFailsWith<IllegalArgumentException> { parseFid("") }
        assertFailsWith<IllegalArgumentException> { parseFid("\u0000") }
        assertFailsWith<IllegalArgumentException> { parseFid("é".repeat(513)) }
    }

    @Test
    fun `message copies and protects its data map`() {
        val source = linkedMapOf(
            "eventType" to "MEETING_REMINDER",
            "schemaVersion" to "1",
            "eventId" to "123e4567-e89b-12d3-a456-426614174000",
            "meetingId" to "42",
            "reminderOffsetMinutes" to "60",
            "issuedAt" to "2026-09-11T20:00:00Z",
            "destination" to "MEETING_DETAILS",
        )
        val message = PushReminderMessage("title", "body", source)
        source["meetingId"] = "99"

        assertEquals("42", message.data["meetingId"])
        assertFailsWith<UnsupportedOperationException> {
            @Suppress("UNCHECKED_CAST")
            (message.data as MutableMap<String, String>)["meetingId"] = "99"
        }
    }
}
