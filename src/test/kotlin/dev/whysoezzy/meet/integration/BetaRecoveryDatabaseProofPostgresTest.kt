package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.dao.DataAccessException
import org.springframework.beans.factory.annotation.Autowired
import tools.jackson.databind.JsonNode
import tools.jackson.databind.ObjectMapper
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BetaRecoveryDatabaseProofPostgresTest : IntegrationTestSupport() {
    private val objectMapper = ObjectMapper()

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `database proof is canonical aggregate-only JSON for empty and beta-populated schemas`() {
        val emptyProof = proof()
        assertCanonicalAndSafe(emptyProof)
        assertEquals(0, emptyProof.path("rows").path("users").intValue(), emptyProof.toString())
        assertEquals(0, emptyProof.path("demoCatalog").path("stateRows").intValue())
        assertEquals(0, emptyProof.path("mediaReferences").path("managedReferences").intValue())

        jdbcTemplate.update(
            """
            INSERT INTO users (name, surname, phone, email, avatar_url)
            VALUES ('Real', 'Member', NULL, 'real@example.test', 'https://example.test/real.png')
            """.trimIndent(),
        )
        val populatedProof = proof()
        assertCanonicalAndSafe(populatedProof)
        assertEquals(1, populatedProof.path("rows").path("users").intValue())
        assertEquals(0, populatedProof.path("rows").path("tags").intValue())
        assertEquals(0, populatedProof.path("demoCatalog").path("stateRows").intValue())
        assertEquals(0, populatedProof.path("authStorage").path("invalidRefreshHashes").intValue())
    }

    @Test
    fun `database proof covers the restored beta catalog without exposing private values`() {
        val bootstrap = applicationContext.getBean(dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapService::class.java)
        bootstrap.bootstrap(
            dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapCommand(
                java.time.LocalDate.of(2099, 1, 1),
                java.time.Instant.parse("2098-12-01T00:00:00Z"),
            ),
        )

        val result = proof()
        assertCanonicalAndSafe(result)
        assertTrue(result.path("schemaChecks").path("requiredIndexes").booleanValue())
        assertTrue(result.path("schemaChecks").path("validatedConstraints").booleanValue())
        assertTrue(result.path("schemaChecks").path("legacyPlaintextColumnsAbsent").booleanValue())
        assertEquals(6, result.path("rows").path("users").intValue(), result.toString())
        assertEquals(6, result.path("rows").path("tags").intValue())
        assertEquals(3, result.path("rows").path("communities").intValue())
        assertEquals(6, result.path("rows").path("meetings").intValue())
        assertEquals(3, result.path("rows").path("ad_blocks").intValue())
        assertEquals(1, result.path("demoCatalog").path("stateRows").intValue())
        assertEquals(1, result.path("demoCatalog").path("matchingStateRows").intValue())
        assertEquals(12, result.path("relationships").path("userInterests").intValue())
        assertEquals(7, result.path("relationships").path("communityTags").intValue())
        assertEquals(9, result.path("relationships").path("communitySubscribers").intValue())
        assertEquals(12, result.path("relationships").path("meetingTags").intValue())
        assertEquals(18, result.path("relationships").path("meetingParticipants").intValue())
        assertEquals(3, result.path("relationships").path("adBlockCommunities").intValue())
        assertEquals(4, result.path("relationships").path("adBlockUsers").intValue())
        assertEquals(0, result.path("relationships").path("orphanRows").intValue())
        assertEquals(0, result.path("relationships").path("duplicateSourceKeys").intValue())
        assertEquals(0, result.path("authStorage").path("invalidOtpRows").intValue())
        assertEquals(0, result.path("authStorage").path("invalidRefreshHashes").intValue())
        assertEquals(0, result.path("authStorage").path("blankIdentityRows").intValue())
        assertEquals(0, result.path("authStorage").path("duplicateIdentityRows").intValue())
        assertTrue(result.path("authStorage").path("legacyPlaintextColumnsAbsent").booleanValue())
        assertTrue(result.path("demoCatalog").path("stateCoherent").booleanValue())
        assertEquals(0, result.path("demoCatalog").path("ownershipKeyViolations").intValue())
        assertEquals(15, result.path("mediaReferences").path("managedReferences").intValue())
        assertEquals(0, result.path("mediaReferences").path("unsafeManagedReferences").intValue())
    }

    @Test
    fun `database proof rejects invalid flyway history`() {
        jdbcTemplate.update("UPDATE flyway_schema_history SET success = false WHERE version = '9'")
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.update("UPDATE flyway_schema_history SET success = true WHERE version = '9'")
        }
    }

    @Test
    fun `database proof rejects invalid schema`() {
        jdbcTemplate.execute("ALTER TABLE meetings DROP COLUMN ends_at")
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.execute("ALTER TABLE meetings ADD COLUMN ends_at BIGINT")
        }
    }

    @Test
    fun `database proof rejects invalid index`() {
        jdbcTemplate.execute("DROP INDEX uq_meetings_source_external")
        jdbcTemplate.execute(
            "CREATE UNIQUE INDEX uq_meetings_source_external ON meetings (source_external_id, source) " +
                "WHERE source_external_id IS NOT NULL",
        )
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.execute("DROP INDEX uq_meetings_source_external")
            jdbcTemplate.execute(
                "CREATE UNIQUE INDEX uq_meetings_source_external ON meetings (source, source_external_id) " +
                    "WHERE source_external_id IS NOT NULL",
            )
        }
    }

    @Test
    fun `database proof rejects a missing relationship constraint`() {
        jdbcTemplate.execute("ALTER TABLE user_interests DROP CONSTRAINT user_interests_user_id_fkey")
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.execute(
                "ALTER TABLE user_interests ADD CONSTRAINT user_interests_user_id_fkey " +
                    "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
            )
        }
    }

    @Test
    fun `database proof rejects unvalidated constraint`() {
        jdbcTemplate.execute("ALTER TABLE users DROP CONSTRAINT ck_users_demo_catalog_key_nonblank")
        jdbcTemplate.execute(
            "ALTER TABLE users ADD CONSTRAINT ck_users_demo_catalog_key_nonblank " +
                "CHECK (demo_catalog_key IS NULL OR btrim(demo_catalog_key) <> '') NOT VALID",
        )
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.execute("ALTER TABLE users DROP CONSTRAINT ck_users_demo_catalog_key_nonblank")
            jdbcTemplate.execute(
                "ALTER TABLE users ADD CONSTRAINT ck_users_demo_catalog_key_nonblank " +
                    "CHECK (demo_catalog_key IS NULL OR btrim(demo_catalog_key) <> '')",
            )
        }
    }

    @Test
    fun `database proof rejects orphaned relationships`() {
        jdbcTemplate.execute("ALTER TABLE user_interests DROP CONSTRAINT user_interests_user_id_fkey")
        jdbcTemplate.execute("ALTER TABLE user_interests DROP CONSTRAINT user_interests_tag_id_fkey")
        jdbcTemplate.update("INSERT INTO user_interests (user_id, tag_id) VALUES (9223372036854775807, 9223372036854775806)")
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.update(
                "DELETE FROM user_interests WHERE user_id = 9223372036854775807 AND tag_id = 9223372036854775806",
            )
            jdbcTemplate.execute(
                "ALTER TABLE user_interests ADD CONSTRAINT user_interests_user_id_fkey " +
                    "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
            )
            jdbcTemplate.execute(
                "ALTER TABLE user_interests ADD CONSTRAINT user_interests_tag_id_fkey " +
                    "FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE",
            )
        }
    }

    @Test
    fun `database proof rejects invalid auth storage`() {
        jdbcTemplate.execute("ALTER TABLE otp_codes DROP CONSTRAINT chk_otp_codes_hash_length")
        jdbcTemplate.update(
            """
            INSERT INTO otp_codes (
                identifier, channel, code_hash, hash_salt, hash_key_id, status,
                failed_attempts, max_attempts, expires_at
            ) VALUES ('+15550000001', 'PHONE', decode('00', 'hex'), decode(repeat('00', 16), 'hex'),
                       'test-key', 'PENDING', 0, 5, CURRENT_TIMESTAMP)
            """.trimIndent(),
        )
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.update("DELETE FROM otp_codes WHERE identifier = '+15550000001'")
            jdbcTemplate.execute(
                "ALTER TABLE otp_codes ADD CONSTRAINT chk_otp_codes_hash_length " +
                    "CHECK (octet_length(code_hash) = 32)",
            )
        }
    }

    @Test
    fun `database proof rejects incoherent demo state`() {
        jdbcTemplate.update(
            """
            INSERT INTO demo_catalog_state (
                catalog_name, manifest_version, schedule_anchor_date, catalog_valid_through, applied_at
            ) VALUES ('unexpected-catalog', 'unexpected-manifest', CURRENT_DATE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """.trimIndent(),
        )
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.update("DELETE FROM demo_catalog_state WHERE catalog_name = 'unexpected-catalog'")
        }
    }

    @Test
    fun `database proof rejects unsafe managed media reference`() {
        jdbcTemplate.update(
            """
            INSERT INTO users (name, surname, phone, email, avatar_url)
            VALUES ('Media', 'Reference', NULL, 'invalid-media-reference@example.test',
                    'https://api.whysoezzy.online/demo-assets/v1/../escape.png')
            """.trimIndent(),
        )
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.update("DELETE FROM users WHERE email = 'invalid-media-reference@example.test'")
        }
    }

    @Test
    fun `database proof rejects an empty managed media reference`() {
        jdbcTemplate.update(
            """
            INSERT INTO users (name, surname, phone, email, avatar_url)
            VALUES ('Media', 'Reference', NULL, 'empty-media-reference@example.test',
                    'https://api.whysoezzy.online/demo-assets/v1')
            """.trimIndent(),
        )
        try {
            assertProofRejected()
        } finally {
            jdbcTemplate.update("DELETE FROM users WHERE email = 'empty-media-reference@example.test'")
        }
    }

    @Autowired
    private lateinit var applicationContext: org.springframework.context.ApplicationContext

    private fun proof(): JsonNode {
        val json = requireNotNull(jdbcTemplate.queryForObject(proofSql, String::class.java))
        return objectMapper.readTree(json)
    }

    private val proofSql: String
        get() = Files.readString(
            Path.of("scripts", "beta-recovery-database-proof.sql"),
        )

    private fun assertCanonicalAndSafe(proof: JsonNode) {
        assertEquals("meet-backend/closed-beta-database-proof/v1", proof.path("schema").textValue())
        assertTrue(proof.path("valid").booleanValue())
        assertEquals(
            listOf(
                "auth",
                "constraints",
                "demoCatalog",
                "flyway",
                "indexes",
                "mediaReferences",
                "relationships",
                "schema",
                "tables",
            ),
            proof.path("validity").propertyNames().asSequence().toList().sorted(),
        )
        val serialized = objectMapper.writeValueAsString(proof)
        assertEquals(serialized, proof.toString())
        assertFalse(serialized.contains("example.test"))
        assertFalse(serialized.contains("beta-demo-person"))
        assertFalse(serialized.contains("https://"))
        assertTrue(proof.path("schemaChecks").path("requiredTablesAndColumns").booleanValue())
        assertTrue(proof.path("schemaChecks").path("exactRequiredTableCount").booleanValue())
        assertTrue(proof.path("schemaChecks").path("requiredConstraints").booleanValue())
        assertTrue(proof.path("flyway").path("orderedV1ToV9").booleanValue())
    }

    private fun assertProofRejected() {
        assertFailsWith<DataAccessException> {
            proof()
        }
    }
}
