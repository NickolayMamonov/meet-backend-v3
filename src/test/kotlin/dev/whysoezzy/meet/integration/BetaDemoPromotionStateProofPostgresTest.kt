package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapCommand
import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapService
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import tools.jackson.databind.ObjectMapper
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.time.LocalDate
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BetaDemoPromotionStateProofPostgresTest : IntegrationTestSupport() {
    private val objectMapper = ObjectMapper()

    @Autowired
    private lateinit var bootstrapService: DemoCatalogBootstrapService

    @BeforeEach
    fun clearDatabase() {
        resetDatabase()
        // The approved stable fixture owns the generated-ID map. This is
        // deliberately test-only; runtime admission never changes sequences.
        jdbcTemplate.execute("SELECT setval('users_id_seq', 1, true)")
    }

    @Test
    fun `stable proof is byte equal to the approved populated catalog fixture`() {
        bootstrap()

        val actual = requireNotNull(stableProof())
        val expected = Files.readString(Path.of("scripts", "fixtures", "test-vps-beta-demo", "canonical-stable-proof.json"))
        val contract = objectMapper.readTree(
            Files.readString(Path.of("scripts", "test-vps-admission-contract.json")),
        )

        assertEquals("meet-backend/test-vps-admission-contract/v1", contract.path("schema").textValue())
        assertEquals("closed-beta-demo", contract.path("populated").path("catalogName").textValue())
        assertEquals("2026-08-15.v1", contract.path("populated").path("manifestVersion").textValue())
        assertEquals(6867, contract.path("populated").path("stableProof").path("byteLength").intValue())
        assertEquals(
            "0e6ef8d48515b3041000166a5506df2a72c11c4e702d7d28960f54d1c204080e",
            contract.path("populated").path("stableProof").path("sha256").textValue(),
        )
        assertEquals(expected, "$actual\n")
    }

    @Test
    fun `stable proof rejects schedule and relationship drift`() {
        bootstrap()

        jdbcTemplate.update(
            "UPDATE meetings SET date = '29.09.2026' " +
                "WHERE demo_catalog_key = 'closed-beta-demo/meeting/board-games'",
        )
        assertNull(stableProof())

        jdbcTemplate.update(
            "UPDATE meetings SET date = '28.09.2026' " +
                "WHERE demo_catalog_key = 'closed-beta-demo/meeting/board-games'",
        )
        jdbcTemplate.update(
            """
            DELETE FROM meeting_tags
            WHERE meeting_id = (
                SELECT id FROM meetings
                WHERE demo_catalog_key = 'closed-beta-demo/meeting/board-games'
            )
            AND tag_id = (
                SELECT id FROM tags
                WHERE demo_catalog_key = 'closed-beta-demo/tag/networking'
            )
            """.trimIndent(),
        )
        assertNull(stableProof())
    }

    @Test
    fun `stable proof rejects generated ID host state and root drift`() {
        resetDatabase()
        jdbcTemplate.execute("SELECT setval('users_id_seq', 3, true)")
        bootstrap()
        assertNull(stableProof())

        resetDatabase()
        jdbcTemplate.execute("SELECT setval('users_id_seq', 1, true)")
        bootstrap()
        jdbcTemplate.update(
            """
            UPDATE meetings
            SET person_host_id = (SELECT id FROM users WHERE demo_catalog_key = 'closed-beta-demo/user/02')
            WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'
            """.trimIndent(),
        )
        assertNull(stableProof())

        resetDatabase()
        jdbcTemplate.execute("SELECT setval('users_id_seq', 1, true)")
        bootstrap()
        jdbcTemplate.update(
            "UPDATE demo_catalog_state SET manifest_version = '2026-08-15.v2' " +
                "WHERE catalog_name = 'closed-beta-demo'",
        )
        assertNull(stableProof())

        resetDatabase()
        jdbcTemplate.execute("SELECT setval('users_id_seq', 1, true)")
        bootstrap()
        jdbcTemplate.update(
            "DELETE FROM ad_blocks WHERE demo_catalog_key = 'closed-beta-demo/ad/people'",
        )
        assertNull(stableProof())
    }

    @Test
    fun `public proof projects all four anonymous response families`() {
        bootstrap()

        val proof = objectMapper.readTree(requireNotNull(publicProof()))
        assertEquals(6, proof.path("meetings").size())
        assertEquals(3, proof.path("recommendedCommunities").size())
        assertEquals(6, proof.path("tags").path("data").size())
        assertEquals(3, proof.path("ads").size())
        assertTrue(proof.path("tags").path("success").booleanValue())
        assertTrue(proof.path("tags").path("message").isNull)
        assertTrue(proof.path("tags").path("error").isNull)

        val meeting = proof.path("meetings").first()
        listOf(
            "id",
            "imageUrl",
            "title",
            "description",
            "time",
            "date",
            "address",
            "capacity",
            "tags",
            "personHost",
            "communityHost",
            "participants",
            "meetingStatus",
            "isUserInParticipants",
            "source",
            "externalUrl",
            "isOnline",
        ).forEach { assertTrue(meeting.has(it), "missing meeting field: $it") }
        assertNotNull(meeting.path("address").path("latitude").doubleValue())
        assertEquals("ACTIVE", meeting.path("meetingStatus").textValue())
        assertEquals(false, meeting.path("isUserInParticipants").booleanValue())
        assertEquals("MANUAL", meeting.path("source").textValue())
    }

    @Test
    fun `public proof rejects established scalar and nested relationship drift`() {
        bootstrap()

        val mutations = listOf(
            "UPDATE meetings SET title = '[ДЕМО] изменено' WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE meetings SET address = 'Изменённый адрес' WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE meetings SET source = 'TIMEPAD' WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE meetings SET is_online = true WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE ad_blocks SET action_url = '/unexpected' WHERE demo_catalog_key = 'closed-beta-demo/ad/interests'",
            """
            DELETE FROM meeting_participants
            WHERE meeting_id = (SELECT id FROM meetings WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome')
              AND user_id = (SELECT id FROM users WHERE demo_catalog_key = 'closed-beta-demo/user/02')
            """.trimIndent(),
        )
        mutations.forEach { mutation ->
            jdbcTemplate.update(mutation)
            assertNull(publicProof(), "public proof accepted drift from: $mutation")
            bootstrap()
        }
    }

    private fun bootstrap() {
        bootstrapService.bootstrap(
            DemoCatalogBootstrapCommand(
                scheduleAnchorDate = LocalDate.of(2026, 9, 14),
                catalogValidThrough = Instant.parse("2026-09-14T00:00:00Z"),
            ),
        )
    }

    private fun stableProof(): String? =
        jdbcTemplate.queryForObject(
            Files.readString(Path.of("scripts", "test-vps-beta-demo-stable-proof.sql")),
            String::class.java,
        )

    private fun publicProof(): String? =
        jdbcTemplate.queryForObject(
            Files.readString(Path.of("scripts", "test-vps-beta-demo-public-proof.sql")),
            String::class.java,
        )
}
