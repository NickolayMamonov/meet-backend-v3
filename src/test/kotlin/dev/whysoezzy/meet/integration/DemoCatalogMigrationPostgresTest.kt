package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.dao.DataIntegrityViolationException
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class DemoCatalogMigrationPostgresTest : IntegrationTestSupport() {
    @Test
    fun `V9 creates nullable ownership keys partial uniqueness and state`() {
        val columns = jdbcTemplate.queryForList(
            """
            SELECT table_name, column_name, is_nullable
            FROM information_schema.columns
            WHERE column_name = 'demo_catalog_key'
            ORDER BY table_name
            """.trimIndent(),
        )
        assertEquals(setOf("ad_blocks", "communities", "meetings", "tags", "users"), columns.map { it["table_name"] }.toSet())
        assertEquals(5, columns.count { it["is_nullable"] == "YES" })
        assertEquals(1, jdbcTemplate.queryForObject("SELECT count(*) FROM demo_catalog_state", Long::class.java))
        assertNotNull(
            jdbcTemplate.queryForObject(
                "SELECT 1 FROM pg_indexes WHERE indexname = 'uq_users_demo_catalog_key'",
                Int::class.java,
            ),
        )
    }

    @Test
    fun `blank ownership key is rejected`() {
        assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update(
                "INSERT INTO tags(text, demo_catalog_key) VALUES (?, ?)",
                "temporary",
                " ",
            )
        }
    }
}
