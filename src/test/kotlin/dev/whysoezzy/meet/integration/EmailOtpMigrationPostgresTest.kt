package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.support.PostgresTestDatabase
import org.flywaydb.core.Flyway
import org.flywaydb.core.api.MigrationVersion
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.jdbc.core.JdbcTemplate
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

@Tag("postgres")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class EmailOtpMigrationPostgresTest {
    private lateinit var database: PostgresTestDatabase
    private lateinit var jdbc: JdbcTemplate

    @BeforeAll
    fun setUpDatabase() {
        database = PostgresTestDatabase("email_otp_migration")
        jdbc = JdbcTemplate(database.dataSource())
    }

    @AfterAll
    fun closeDatabase() = database.close()

    @Test
    fun `migrates V5 data transactionally without retaining plaintext or linking profile emails`() {
        flyway(MigrationVersion.fromVersion("5")).migrate()
        val unrelatedSchemaBefore = schemaFingerprint("meetings", "ingestion_runs")
        val userId = jdbc.queryForObject(
            """
            INSERT INTO users (name, surname, phone, email)
            VALUES ('Legacy', 'Phone', '+15550000001', 'unverified@example.test')
            RETURNING id
            """.trimIndent(),
            Long::class.java,
        )
        jdbc.update(
            """
            INSERT INTO otp_codes (phone, code, expires_at, is_used)
            VALUES ('+15550000001', '123456', clock_timestamp() + INTERVAL '5 minutes', false)
            """.trimIndent(),
        )

        flyway(MigrationVersion.fromVersion("6")).migrate()

        assertEquals(0L, jdbc.count("otp_codes"))
        assertEquals(
            1L,
            jdbc.queryForObject(
                """
                SELECT COUNT(*) FROM auth_identities
                WHERE user_id = ? AND type = 'PHONE' AND normalized_identifier = '+15550000001'
                """.trimIndent(),
                Long::class.java,
                userId,
            ),
        )
        assertEquals(0L, jdbc.queryForObject("SELECT COUNT(*) FROM auth_identities WHERE type = 'EMAIL'", Long::class.java))
        assertEquals(
            "unverified@example.test",
            jdbc.queryForObject("SELECT email FROM users WHERE id = ?", String::class.java, userId),
        )

        assertEquals(
            listOf(
                ColumnSpec("id", "bigint", null, false, "nextval('auth_identities_id_seq'::regclass)"),
                ColumnSpec("user_id", "bigint", null, false, null),
                ColumnSpec("type", "character varying", 16, false, null),
                ColumnSpec("normalized_identifier", "character varying", 254, false, null),
                ColumnSpec("created_at", "timestamp without time zone", null, false, "CURRENT_TIMESTAMP"),
            ),
            columns("auth_identities"),
        )
        assertEquals(
            listOf(
                ColumnSpec("id", "bigint", null, false, "nextval('otp_codes_id_seq'::regclass)"),
                ColumnSpec("identifier", "character varying", 254, false, null),
                ColumnSpec("expires_at", "timestamp without time zone", null, false, null),
                ColumnSpec("created_at", "timestamp without time zone", null, false, "CURRENT_TIMESTAMP"),
                ColumnSpec("channel", "character varying", 16, false, null),
                ColumnSpec("code_hash", "bytea", null, false, null),
                ColumnSpec("hash_salt", "bytea", null, false, null),
                ColumnSpec("hash_key_id", "character varying", 32, false, null),
                ColumnSpec("status", "character varying", 24, false, null),
                ColumnSpec("failed_attempts", "integer", null, false, "0"),
                ColumnSpec("max_attempts", "integer", null, false, null),
                ColumnSpec("activated_at", "timestamp without time zone", null, true, null),
                ColumnSpec("consumed_at", "timestamp without time zone", null, true, null),
            ),
            columns("otp_codes"),
        )
        assertEquals(
            listOf(
                ColumnSpec("id", "bigint", null, false, "nextval('otp_rate_limit_attempts_id_seq'::regclass)"),
                ColumnSpec("scope", "character varying", 16, false, null),
                ColumnSpec("subject_key", "character", 64, false, null),
                ColumnSpec("attempted_at", "timestamp without time zone", null, false, "CURRENT_TIMESTAMP"),
            ),
            columns("otp_rate_limit_attempts"),
        )
        assertEquals(
            ColumnSpec("phone", "character varying", 20, true, null),
            columns("users").single { it.name == "phone" },
        )
        assertFalse(columns("otp_codes").any { it.name == "code" || it.name == "is_used" })

        assertEquals(
            IndexSpec(
                unique = false,
                columns = listOf("channel", "identifier", "id"),
                descending = listOf(false, false, true),
                predicate = null,
            ),
            index("idx_otp_codes_channel_identifier_latest"),
        )
        assertEquals(
            IndexSpec(
                unique = true,
                columns = listOf("channel", "identifier"),
                descending = listOf(false, false),
                predicate = "status::text='ACTIVE'::text",
            ),
            index("uq_otp_codes_active"),
        )
        assertEquals(
            IndexSpec(
                unique = false,
                columns = listOf("status", "expires_at", "id"),
                descending = listOf(false, false, false),
                predicate = null,
            ),
            index("idx_otp_codes_status_expires_id"),
        )

        val constraintDefinitions = jdbc.query(
            """
            SELECT conname, pg_get_constraintdef(oid) AS definition
            FROM pg_constraint
            WHERE connamespace = current_schema()::regnamespace
              AND conrelid IN ('auth_identities'::regclass, 'otp_codes'::regclass, 'otp_rate_limit_attempts'::regclass)
            """.trimIndent(),
        ) { row, _ -> row.getString("conname") to row.getString("definition") }.toMap()
        assertEquals(
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
            constraintDefinitions["auth_identities_user_id_fkey"],
        )
        assertEquals(
            "UNIQUE (type, normalized_identifier)",
            constraintDefinitions["uq_auth_identities_type_identifier"],
        )
        assertEquals("UNIQUE (user_id, type)", constraintDefinitions["uq_auth_identities_user_type"])
        assertEquals(
            setOf(
                "auth_identities_pkey",
                "auth_identities_user_id_fkey",
                "uq_auth_identities_type_identifier",
                "uq_auth_identities_user_type",
                "chk_auth_identities_type",
                "chk_auth_identities_identifier_nonblank",
                "otp_codes_pkey",
                "chk_otp_codes_channel",
                "chk_otp_codes_status",
                "chk_otp_codes_identifier_nonblank",
                "chk_otp_codes_hash_length",
                "chk_otp_codes_salt_length",
                "chk_otp_codes_hash_key_id",
                "chk_otp_codes_attempts",
                "otp_rate_limit_attempts_pkey",
                "chk_otp_rate_limit_scope",
            ),
            constraintDefinitions.keys,
        )
        mapOf(
            "chk_auth_identities_type" to listOf("PHONE", "EMAIL"),
            "chk_auth_identities_identifier_nonblank" to listOf("btrim", "normalized_identifier"),
            "chk_otp_codes_channel" to listOf("PHONE", "EMAIL"),
            "chk_otp_codes_status" to listOf(
                "PENDING",
                "ACTIVE",
                "CONSUMED",
                "EXHAUSTED",
                "EXPIRED",
                "SUPERSEDED",
                "DELIVERY_FAILED",
            ),
            "chk_otp_codes_identifier_nonblank" to listOf("btrim", "identifier"),
            "chk_otp_codes_hash_length" to listOf("octet_length(code_hash)", "32"),
            "chk_otp_codes_salt_length" to listOf("octet_length(hash_salt)", "16"),
            "chk_otp_codes_hash_key_id" to listOf("A-Za-z0-9._~-", "1,32"),
            "chk_otp_codes_attempts" to listOf("failed_attempts", "max_attempts", "10"),
            "chk_otp_rate_limit_scope" to listOf(
                "phone",
                "email",
                "ip",
                "device",
                "verify_phone",
                "verify_email",
                "verify_ip",
                "verify_device",
            ),
        ).forEach { (name, requiredFragments) ->
            val definition = constraintDefinitions.getValue(name)
            requiredFragments.forEach { fragment ->
                assertTrue(fragment in definition, "$name must retain its complete approved check")
            }
        }

        jdbc.update("INSERT INTO users (name, surname, phone) VALUES ('Null', 'One', NULL)")
        jdbc.update("INSERT INTO users (name, surname, phone) VALUES ('Null', 'Two', NULL)")
        assertFailsWith<DataIntegrityViolationException> {
            jdbc.update("INSERT INTO users (name, surname, phone) VALUES ('Duplicate', 'Phone', '+15550000001')")
        }

        assertEquals(unrelatedSchemaBefore, schemaFingerprint("meetings", "ingestion_runs"))
        listOf("otp_rate_limit_attempts", "auth_identities").forEach { table ->
            assertTrue(jdbc.tableExists(table), "$table must exist")
        }

        assertFalse(jdbc.indexExists("idx_otp_codes_expires_id"))
        flyway(MigrationVersion.fromVersion("6")).validate()
        flyway().migrate()
        assertEquals(
            IndexSpec(
                unique = false,
                columns = listOf("expires_at", "id"),
                descending = listOf(false, false),
                predicate = null,
            ),
            index("idx_otp_codes_expires_id"),
        )
        assertTrue(jdbc.indexIsReady("idx_otp_codes_expires_id"))
        assertTrue(jdbc.indexIsValid("idx_otp_codes_expires_id"))
        flyway().validate()
    }

    private fun flyway(target: MigrationVersion? = null): Flyway {
        val configuration = Flyway.configure()
            .dataSource(database.jdbcUrl, database.username, database.password)
            .locations("classpath:db/migration")
        target?.let(configuration::target)
        return configuration.load()
    }

    private fun JdbcTemplate.count(table: String): Long =
        requireNotNull(queryForObject("SELECT COUNT(*) FROM $table", Long::class.java))

    private fun JdbcTemplate.tableExists(table: String): Boolean =
        queryForObject(
            """
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = current_schema() AND table_name = ?
            )
            """.trimIndent(),
            Boolean::class.java,
            table,
        )

    private fun JdbcTemplate.indexExists(name: String): Boolean =
        queryForObject(
            """
            SELECT EXISTS (
                SELECT 1
                FROM pg_class index_class
                JOIN pg_namespace namespace ON namespace.oid = index_class.relnamespace
                WHERE namespace.nspname = current_schema() AND index_class.relname = ?
            )
            """.trimIndent(),
            Boolean::class.java,
            name,
        )

    private fun JdbcTemplate.indexIsReady(name: String): Boolean =
        queryForObject(
            """
            SELECT i.indisready
            FROM pg_index i
            JOIN pg_class index_class ON index_class.oid = i.indexrelid
            JOIN pg_namespace namespace ON namespace.oid = index_class.relnamespace
            WHERE namespace.nspname = current_schema() AND index_class.relname = ?
            """.trimIndent(),
            Boolean::class.java,
            name,
        )

    private fun JdbcTemplate.indexIsValid(name: String): Boolean =
        queryForObject(
            """
            SELECT i.indisvalid
            FROM pg_index i
            JOIN pg_class index_class ON index_class.oid = i.indexrelid
            JOIN pg_namespace namespace ON namespace.oid = index_class.relnamespace
            WHERE namespace.nspname = current_schema() AND index_class.relname = ?
            """.trimIndent(),
            Boolean::class.java,
            name,
        )

    private fun columns(table: String): List<ColumnSpec> =
        jdbc.query(
            """
            SELECT column_name, data_type, character_maximum_length, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = ?
            ORDER BY ordinal_position
            """.trimIndent(),
            { row, _ ->
                ColumnSpec(
                    name = row.getString("column_name"),
                    type = row.getString("data_type"),
                    length = row.getObject("character_maximum_length")?.let { row.getInt("character_maximum_length") },
                    nullable = row.getString("is_nullable") == "YES",
                    default = row.getString("column_default")?.normalizeColumnDefault(),
                )
            },
            table,
        )

    private fun index(name: String): IndexSpec =
        requireNotNull(
            jdbc.queryForObject(
                """
                SELECT i.indisunique,
                       ARRAY(
                           SELECT pg_get_indexdef(i.indexrelid, key_position, true)
                           FROM generate_series(1, i.indnkeyatts) AS key_position
                           ORDER BY key_position
                       ) AS columns,
                       ARRAY(
                           SELECT (i.indoption[key_position - 1] & 1) = 1
                           FROM generate_series(1, i.indnkeyatts) AS key_position
                           ORDER BY key_position
                       ) AS descending,
                       pg_get_expr(i.indpred, i.indrelid) AS predicate
                FROM pg_index i
                JOIN pg_class index_class ON index_class.oid = i.indexrelid
                JOIN pg_namespace namespace ON namespace.oid = index_class.relnamespace
                WHERE namespace.nspname = current_schema() AND index_class.relname = ?
                """.trimIndent(),
                { row, _ ->
                    IndexSpec(
                        unique = row.getBoolean("indisunique"),
                        columns = (row.getArray("columns").array as Array<*>).map { it.toString() },
                        descending = (row.getArray("descending").array as Array<*>).map { it as Boolean },
                        predicate = row.getString("predicate")?.normalizeCatalogExpression(),
                    )
                },
                name,
            ),
        )

    private fun schemaFingerprint(vararg tables: String): List<String> {
        require(tables.isNotEmpty())
        val placeholders = tables.joinToString { "?" }
        val arguments = Array<Any>(tables.size * 3) { index -> tables[index % tables.size] }
        return jdbc.queryForList(
            """
            SELECT fingerprint
            FROM (
                SELECT table_name,
                       'column:' || ordinal_position || ':' || column_name || ':' || data_type || ':' ||
                       COALESCE(character_maximum_length::text, '') || ':' || is_nullable || ':' ||
                       COALESCE(column_default, '') AS fingerprint
                FROM information_schema.columns
                WHERE table_schema = current_schema() AND table_name IN ($placeholders)
                UNION ALL
                SELECT table_class.relname,
                       'constraint:' || catalog_constraint.conname || ':' ||
                       pg_get_constraintdef(catalog_constraint.oid)
                FROM pg_constraint catalog_constraint
                JOIN pg_class table_class ON table_class.oid = catalog_constraint.conrelid
                JOIN pg_namespace namespace ON namespace.oid = table_class.relnamespace
                WHERE namespace.nspname = current_schema() AND table_class.relname IN ($placeholders)
                UNION ALL
                SELECT table_class.relname,
                       'index:' || index_class.relname || ':' || pg_get_indexdef(index_class.oid)
                FROM pg_index index_catalog
                JOIN pg_class table_class ON table_class.oid = index_catalog.indrelid
                JOIN pg_class index_class ON index_class.oid = index_catalog.indexrelid
                JOIN pg_namespace namespace ON namespace.oid = table_class.relnamespace
                WHERE namespace.nspname = current_schema() AND table_class.relname IN ($placeholders)
            ) catalog
            ORDER BY table_name, fingerprint
            """.trimIndent(),
            String::class.java,
            *arguments,
        )
    }

    private fun String.normalizeCatalogExpression(): String =
        replace("(", "")
            .replace(")", "")
            .replace(Regex("\\s+"), "")

    private fun String.normalizeColumnDefault(): String {
        if (!startsWith("nextval(")) {
            return this
        }
        val qualifiedSequence = substringAfter('\'').substringBefore('\'')
        val sequence = qualifiedSequence.substringAfterLast('.').removeSurrounding("\"")
        return "nextval('$sequence'::regclass)"
    }

    private data class ColumnSpec(
        val name: String,
        val type: String,
        val length: Int?,
        val nullable: Boolean,
        val default: String?,
    )

    private data class IndexSpec(
        val unique: Boolean,
        val columns: List<String>,
        val descending: List<Boolean>,
        val predicate: String?,
    )
}
