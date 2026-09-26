package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RealCatalogMigrationPostgresTest : IntegrationTestSupport() {
    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `V11 creates additive real catalog schema and leaves existing rows unowned`() {
        val columns = jdbcTemplate.queryForList(
            """
            SELECT table_name, column_name
            FROM information_schema.columns
            WHERE table_name IN ('real_catalog_revisions', 'real_catalog_state')
            ORDER BY table_name, column_name
            """.trimIndent(),
        )
        assertEquals(
            28,
            columns.size,
            "V11 must expose the complete revision/state contract",
        )
        assertEquals(
            0,
            jdbcTemplate.queryForObject(
                "SELECT count(*) FROM meetings WHERE real_catalog_key IS NOT NULL",
                Long::class.java,
            ),
        )
        assertEquals(
            0,
            jdbcTemplate.queryForObject(
                "SELECT count(*) FROM communities WHERE real_catalog_key IS NOT NULL",
                Long::class.java,
            ),
        )
        assertTrue(
            jdbcTemplate.queryForObject(
                "SELECT count(*) FROM pg_indexes WHERE indexname = 'uq_meetings_real_catalog_item'",
                Int::class.java,
            )!! > 0,
        )
    }

    @Test
    fun `real catalog ownership is all-or-nothing and demo ownership is excluded`() {
        val constraintNames = jdbcTemplate.queryForList(
            """
            SELECT conname
            FROM pg_constraint
            WHERE conname IN (
                'ck_meetings_real_catalog_ownership',
                'ck_communities_real_catalog_ownership',
                'fk_meetings_real_catalog_state',
                'fk_communities_real_catalog_state'
            )
            ORDER BY conname
            """.trimIndent(),
        ).map { it["conname"] }
        assertEquals(
            listOf(
                "ck_communities_real_catalog_ownership",
                "ck_meetings_real_catalog_ownership",
                "fk_communities_real_catalog_state",
                "fk_meetings_real_catalog_state",
            ),
            constraintNames,
        )
    }
}
