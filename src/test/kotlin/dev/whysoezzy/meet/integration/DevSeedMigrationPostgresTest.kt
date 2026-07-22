package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.support.PostgresTestDatabase
import org.flywaydb.core.Flyway
import org.flywaydb.core.api.MigrationVersion
import org.flywaydb.core.api.exception.FlywayValidateException
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.springframework.jdbc.core.JdbcTemplate
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

@Tag("postgres")
class DevSeedMigrationPostgresTest {
    @Test
    fun `fresh dev schema seeds and repeated migration is safe`() = withDatabase("fresh") { database, jdbc ->
        devFlyway(database).migrate()
        assertSeeded(jdbc)

        devFlyway(database).migrate()
        assertSeeded(jdbc)
        devFlyway(database).validate()
    }

    @Test
    fun `current versioned dev database can add the repeatable seed`() =
        withDatabase("current") { database, jdbc ->
            versionedFlyway(database).migrate()
            assertEquals(0L, jdbc.count("users"))

            devFlyway(database).migrate()

            assertSeeded(jdbc)
            devFlyway(database).validate()
        }

    @Test
    fun `partial existing application data is preserved without partial reseeding`() =
        withDatabase("partial") { database, jdbc ->
            versionedFlyway(database).migrate()
            jdbc.update("INSERT INTO tags (text) VALUES ('operator-created')")
            jdbc.update(
                """
                INSERT INTO users (name, surname, phone, email)
                VALUES ('Existing', 'Developer', '+15550009999', 'existing@example.test')
                """.trimIndent(),
            )

            devFlyway(database).migrate()

            assertEquals(1L, jdbc.count("tags"))
            assertEquals(1L, jdbc.count("users"))
            assertEquals("operator-created", jdbc.queryForObject("SELECT text FROM tags", String::class.java))
            assertEquals("existing@example.test", jdbc.queryForObject("SELECT email FROM users", String::class.java))
            devFlyway(database).validate()
        }

    @Test
    fun `supported legacy V2 dev history is repaired before validation`() =
        withDatabase("legacy") { database, jdbc ->
            versionedFlyway(database, MigrationVersion.fromVersion("1")).migrate()
            insertHistoryRow(jdbc, 1174224222)

            devFlyway(database).migrate()

            assertFalse(jdbc.columnExists("refresh_tokens", "token"))
            assertTrue(jdbc.columnExists("refresh_tokens", "token_hash"))
            assertEquals(
                "V2__hash_refresh_tokens.sql",
                jdbc.queryForObject(
                    "SELECT script FROM flyway_schema_history WHERE version = '2' AND success = TRUE",
                    String::class.java,
                ),
            )
            assertSeeded(jdbc)
            devFlyway(database).validate()
        }

    @Test
    fun `unsupported legacy V2 history is not silently repaired`() =
        withDatabase("legacy_guard") { database, jdbc ->
            versionedFlyway(database, MigrationVersion.fromVersion("1")).migrate()
            insertHistoryRow(jdbc, 123456789)

            assertFailsWith<FlywayValidateException> { devFlyway(database).validate() }
            assertEquals(
                123456789,
                jdbc.queryForObject(
                    "SELECT checksum FROM flyway_schema_history WHERE version = '2' AND success = TRUE",
                    Int::class.java,
                ),
            )
            assertTrue(jdbc.columnExists("refresh_tokens", "token"))
            assertFalse(jdbc.columnExists("refresh_tokens", "token_hash"))
        }

    private fun assertSeeded(jdbc: JdbcTemplate) {
        assertEquals(12L, jdbc.count("tags"))
        assertEquals(20L, jdbc.count("users"))
        assertEquals(3L, jdbc.count("communities"))
        assertEquals(20L, jdbc.count("meetings"))
        assertEquals(3L, jdbc.count("ad_blocks"))
    }

    private fun insertHistoryRow(jdbc: JdbcTemplate, checksum: Int) {
        jdbc.update(
            """
            INSERT INTO flyway_schema_history
                (installed_rank, version, description, type, script, checksum,
                 installed_by, installed_on, execution_time, success)
            VALUES (
                (SELECT COALESCE(MAX(installed_rank), 0) + 1 FROM flyway_schema_history),
                '2', 'dev seed', 'SQL', 'V2__dev_seed.sql', ?,
                'test', clock_timestamp(), 0, TRUE
            )
            """.trimIndent(),
            checksum,
        )
    }

    private fun <T> withDatabase(name: String, block: (PostgresTestDatabase, JdbcTemplate) -> T): T {
        val database = PostgresTestDatabase("dev_seed_${name}_${UUID.randomUUID().toString().replace("-", "")}")
        return try {
            block(database, JdbcTemplate(database.dataSource()))
        } finally {
            database.close()
        }
    }

    private fun devFlyway(database: PostgresTestDatabase, target: MigrationVersion? = null): Flyway =
        Flyway.configure()
            .dataSource(database.jdbcUrl, database.username, database.password)
            .locations("classpath:db/migration", "classpath:db/seed")
            .apply { target?.let(::target) }
            .load()

    private fun versionedFlyway(database: PostgresTestDatabase, target: MigrationVersion? = null): Flyway =
        Flyway.configure()
            .dataSource(database.jdbcUrl, database.username, database.password)
            .locations("classpath:db/migration")
            .apply { target?.let(::target) }
            .load()

    private fun JdbcTemplate.count(table: String): Long =
        requireNotNull(queryForObject("SELECT COUNT(*) FROM $table", Long::class.java))

    private fun JdbcTemplate.columnExists(table: String, column: String): Boolean =
        requireNotNull(
            queryForObject(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM information_schema.columns
                    WHERE table_schema = current_schema()
                      AND table_name = ?
                      AND column_name = ?
                )
                """.trimIndent(),
                Boolean::class.java,
                table,
                column,
            ),
        )
}
