package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.Meeting
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals

class MeetingEndTimeMigrationPostgresTest : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `additive migration provides nullable bigint ends_at`() {
        val column = jdbcTemplate.queryForMap(
            """
            SELECT data_type, is_nullable
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'meetings'
              AND column_name = 'ends_at'
            """.trimIndent(),
        )
        assertEquals("bigint", column["data_type"])
        assertEquals("YES", column["is_nullable"])

        val legacy = meetings.saveAndFlush(meeting("legacy", null))
        val explicit = meetings.saveAndFlush(meeting("explicit", 1_800_000_000_000L))
        assertEquals(null, meetings.findById(legacy.id!!).orElseThrow().endsAt)
        assertEquals(1_800_000_000_000L, meetings.findById(explicit.id!!).orElseThrow().endsAt)
    }

    private fun meeting(title: String, endsAt: Long?) = Meeting(
        title = title,
        description = "Migration fixture",
        imageUrl = "",
        time = 1_700_000_000_000L,
        date = "01.01.2026",
        address = "Online",
        latitude = 0.0,
        longitude = 0.0,
        endsAt = endsAt,
    )
}
