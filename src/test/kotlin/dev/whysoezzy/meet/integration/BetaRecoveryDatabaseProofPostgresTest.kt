package dev.whysoezzy.meet.integration

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import tools.jackson.databind.JsonNode
import tools.jackson.databind.ObjectMapper
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertEquals
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
        val serialized = objectMapper.writeValueAsString(proof)
        assertEquals(serialized, proof.toString())
        assertFalse(serialized.contains("example.test"))
        assertFalse(serialized.contains("beta-demo-person"))
        assertFalse(serialized.contains("https://"))
        assertTrue(proof.path("schemaChecks").path("requiredTablesAndColumns").booleanValue())
        assertTrue(proof.path("flyway").path("orderedV1ToV9").booleanValue())
    }
}
