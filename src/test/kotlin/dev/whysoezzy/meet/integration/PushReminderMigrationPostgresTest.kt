package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PushReminderMigrationPostgresTest : IntegrationTestSupport() {
    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `V10 creates push tables and meeting start version trigger`() {
        val fixture = fixture()
        val tables = jdbcTemplate.queryForList(
            """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = current_schema()
              AND table_name IN ('push_installations', 'meeting_reminder_claims', 'meeting_reminder_targets')
            ORDER BY table_name
            """.trimIndent(),
            String::class.java,
        )
        assertEquals(
            listOf("meeting_reminder_claims", "meeting_reminder_targets", "push_installations"),
            tables,
        )

        val before = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            fixture.meeting.id,
        )
        jdbcTemplate.update(
            "UPDATE meetings SET time = time + 1000 WHERE id = ?",
            fixture.meeting.id,
        )
        val afterChange = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            fixture.meeting.id,
        )
        jdbcTemplate.update(
            "UPDATE meetings SET time = time - 1000 WHERE id = ?",
            fixture.meeting.id,
        )
        val afterReturn = jdbcTemplate.queryForObject(
            "SELECT push_start_version FROM meetings WHERE id = ?",
            Long::class.java,
            fixture.meeting.id,
        )

        assertEquals(0L, before)
        assertEquals(1L, afterChange)
        assertEquals(2L, afterReturn)
    }
}
