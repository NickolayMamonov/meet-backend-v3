package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.dto.MeetingAddressDto
import dev.whysoezzy.meet.api.dto.MeetingDto
import tools.jackson.module.kotlin.jacksonObjectMapper
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.jupiter.api.Test

class MeetingDtoJsonContractTest {
    @Test
    fun `android meeting dto shape does not expose persistence end time`() {
        val dto = MeetingDto(
            id = 7L,
            imageUrl = "",
            title = "Contract fixture",
            description = "Description",
            time = 1_700_000_000_000L,
            date = "01.01.2026",
            address = MeetingAddressDto("Online", 0.0, 0.0),
            capacity = 10,
            tags = emptyList(),
            personHost = null,
            communityHost = null,
            participants = emptyList(),
            meetingStatus = "ACTIVE",
            isUserInParticipants = false,
        )

        val json = jacksonObjectMapper().writeValueAsString(dto)
        assertTrue(json.contains("\"id\""))
        assertTrue(json.contains("\"time\""))
        assertTrue(json.contains("\"meetingStatus\""))
        assertFalse(json.contains("endsAt"))
        assertFalse(json.contains("ends_at"))
    }
}
