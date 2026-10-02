package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapCommand
import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapService
import dev.whysoezzy.meet.api.error.ConflictException
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.dao.EmptyResultDataAccessException
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.context.annotation.Primary
import tools.jackson.databind.ObjectMapper
import java.sql.Connection
import javax.sql.DataSource
import java.time.Clock
import java.nio.file.Files
import java.nio.file.Path
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@Import(BetaDemoPromotionStateProofPostgresTest.StableDemoClockConfiguration::class)
class BetaDemoPromotionStateProofPostgresTest : IntegrationTestSupport() {
    private val objectMapper = ObjectMapper()

    @Autowired
    private lateinit var bootstrapService: DemoCatalogBootstrapService

    @Autowired
    private lateinit var dataSource: DataSource

    @TestConfiguration(proxyBeanMethods = false)
    class StableDemoClockConfiguration {
        @Bean
        @Primary
        fun stableDemoClock(): Clock =
            Clock.fixed(Instant.parse("2026-08-15T00:00:00Z"), ZoneOffset.UTC)
    }

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
        assertEquals("2027-09-13.v1", contract.path("populated").path("manifestVersion").textValue())
        assertEquals(6867, contract.path("populated").path("stableProof").path("byteLength").intValue())
        assertEquals(
            "6507c415b8a6b5bd42e297b8f1816b48c07b2ee4dcc0011594741a5eb2e6f9e2",
            contract.path("populated").path("stableProof").path("sha256").textValue(),
        )
        assertEquals(expected, "$actual\n")
        val actualBytes = "$actual\n".toByteArray(StandardCharsets.UTF_8)
        assertEquals(
            contract.path("populated").path("stableProof").path("byteLength").intValue(),
            actualBytes.size,
        )
        assertEquals(
            contract.path("populated").path("stableProof").path("sha256").textValue(),
            sha256(actualBytes),
        )
    }

    @Test
    fun `stable proof rejects schedule and relationship drift`() {
        bootstrap()

        jdbcTemplate.update(
            "UPDATE meetings SET date = '28.09.2027' " +
                "WHERE demo_catalog_key = 'closed-beta-demo/meeting/board-games'",
        )
        assertNull(stableProof())

        jdbcTemplate.update(
            "UPDATE meetings SET date = '27.09.2027' " +
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
    fun `renewed schedule and generated ID map match independent expectations`() {
        bootstrap()

        assertEquals(
            mapOf(
                "closed-beta-demo/tag/networking" to 1L,
                "closed-beta-demo/tag/walks" to 2L,
                "closed-beta-demo/tag/board-games" to 3L,
                "closed-beta-demo/tag/public-speaking" to 4L,
                "closed-beta-demo/tag/organizing" to 5L,
                "closed-beta-demo/tag/online" to 6L,
                "closed-beta-demo/user/01" to 2L,
                "closed-beta-demo/user/02" to 3L,
                "closed-beta-demo/user/03" to 4L,
                "closed-beta-demo/user/04" to 5L,
                "closed-beta-demo/user/05" to 6L,
                "closed-beta-demo/user/06" to 7L,
                "closed-beta-demo/community/moscow-meets" to 1L,
                "closed-beta-demo/community/city-walks" to 2L,
                "closed-beta-demo/community/online-club" to 3L,
                "closed-beta-demo/meeting/welcome" to 1L,
                "closed-beta-demo/meeting/organize-online" to 2L,
                "closed-beta-demo/meeting/board-games" to 3L,
                "closed-beta-demo/meeting/vdnkh-walk" to 4L,
                "closed-beta-demo/meeting/networking-online" to 5L,
                "closed-beta-demo/meeting/public-speaking" to 6L,
                "closed-beta-demo/ad/communities" to 1L,
                "closed-beta-demo/ad/interests" to 2L,
                "closed-beta-demo/ad/people" to 3L,
            ),
            rootIds(),
        )
        assertEquals(
            listOf(
                ScheduleTuple("welcome", 1L, 1821456000000L, "20.09.2027", 1821463200000L),
                ScheduleTuple("organize-online", 2L, 1821718800000L, "23.09.2027", 1821724200000L),
                ScheduleTuple("board-games", 3L, 1822062600000L, "27.09.2027", 1822071600000L),
                ScheduleTuple("vdnkh-walk", 4L, 1822636800000L, "04.10.2027", 1822644000000L),
                ScheduleTuple("networking-online", 5L, 1822928400000L, "07.10.2027", 1822933800000L),
                ScheduleTuple("public-speaking", 6L, 1823443200000L, "13.10.2027", 1823450400000L),
            ),
            scheduleTuples(),
        )
    }

    @Test
    fun `repeated renewed bootstrap preserves IDs schedules bytes and unchanged counts`() {
        bootstrap()
        val firstIds = rootIds()
        val firstSchedules = scheduleTuples()
        val firstProof = requireNotNull(stableProof())

        val second = bootstrap()

        assertEquals(6, second.roots.tags.unchanged)
        assertEquals(6, second.roots.users.unchanged)
        assertEquals(3, second.roots.communities.unchanged)
        assertEquals(6, second.roots.meetings.unchanged)
        assertEquals(3, second.roots.adBlocks.unchanged)
        assertEquals(12, second.relationships.userInterests.unchanged)
        assertEquals(7, second.relationships.communityTags.unchanged)
        assertEquals(9, second.relationships.communitySubscribers.unchanged)
        assertEquals(12, second.relationships.meetingTags.unchanged)
        assertEquals(18, second.relationships.meetingParticipants.unchanged)
        assertEquals(6, second.relationships.meetingPersonHosts.unchanged)
        assertEquals(6, second.relationships.meetingCommunityHosts.unchanged)
        assertEquals(3, second.relationships.adBlockCommunities.unchanged)
        assertEquals(4, second.relationships.adBlockUsers.unchanged)
        assertEquals(firstIds, rootIds())
        assertEquals(firstSchedules, scheduleTuples())
        assertEquals(firstProof, stableProof())
    }

    @Test
    fun `unconfirmed old applied schedule rejects atomically and confirmed renewal retains IDs`() {
        bootstrap()
        val idsBefore = rootIds()
        seedOldAppliedSchedule()
        val before = jdbcTemplate.queryForList(
            "SELECT manifest_version, schedule_anchor_date, catalog_valid_through FROM demo_catalog_state",
        )

        assertFailsWith<ConflictException> { bootstrap() }

        assertEquals(before, jdbcTemplate.queryForList(
            "SELECT manifest_version, schedule_anchor_date, catalog_valid_through FROM demo_catalog_state",
        ))
        assertEquals(idsBefore, rootIds())
        assertEquals(
            listOf(
                ScheduleTuple("welcome", 1L, 1790006400000L, "21.09.2026", 1790013600000L),
                ScheduleTuple("organize-online", 2L, 1790269200000L, "24.09.2026", 1790274600000L),
                ScheduleTuple("board-games", 3L, 1790613000000L, "28.09.2026", 1790622000000L),
                ScheduleTuple("vdnkh-walk", 4L, 1791187200000L, "05.10.2026", 1791194400000L),
                ScheduleTuple("networking-online", 5L, 1791478800000L, "08.10.2026", 1791484200000L),
                ScheduleTuple("public-speaking", 6L, 1791993600000L, "14.10.2026", 1792000800000L),
            ),
            scheduleTuples(),
        )

        val confirmed = bootstrap(confirmReschedule = true)
        assertEquals("2027-09-13.v1", confirmed.manifestVersion)
        assertEquals(idsBefore, rootIds())
        assertEquals(
            listOf(
                ScheduleTuple("welcome", 1L, 1821456000000L, "20.09.2027", 1821463200000L),
                ScheduleTuple("organize-online", 2L, 1821718800000L, "23.09.2027", 1821724200000L),
                ScheduleTuple("board-games", 3L, 1822062600000L, "27.09.2027", 1822071600000L),
                ScheduleTuple("vdnkh-walk", 4L, 1822636800000L, "04.10.2027", 1822644000000L),
                ScheduleTuple("networking-online", 5L, 1822928400000L, "07.10.2027", 1822933800000L),
                ScheduleTuple("public-speaking", 6L, 1823443200000L, "13.10.2027", 1823450400000L),
            ),
            scheduleTuples(),
        )
    }

    @Test
    fun `stable and recovery proofs reject the old edition`() {
        bootstrap()
        jdbcTemplate.update(
            "UPDATE demo_catalog_state SET manifest_version = '2026-08-15.v1' " +
                "WHERE catalog_name = 'closed-beta-demo'",
        )

        assertNull(stableProof())
        assertNull(recoveryProof())
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
        assertEquals(
            setOf(
                "id", "imageUrl", "title", "description", "time", "date", "address",
                "capacity", "tags", "personHost", "communityHost", "participants",
                "meetingStatus", "isUserInParticipants", "source", "externalUrl", "isOnline",
            ),
            fieldNames(meeting),
        )
        assertEquals(setOf("address", "latitude", "longitude"), fieldNames(meeting.path("address")))
        assertEquals(setOf("id", "name", "surname", "description", "imageUrl"), fieldNames(meeting.path("personHost")))
        assertEquals(
            setOf("id", "title", "description", "imageUrl", "meetingsInfo"),
            fieldNames(meeting.path("communityHost")),
        )
        assertEquals(setOf("id", "name", "surname", "imageUrl"), fieldNames(meeting.path("participants").first()))
        assertEquals(setOf("id", "text"), fieldNames(meeting.path("tags").first()))
        assertEquals(
            setOf("id", "title", "imageUrl", "date"),
            fieldNames(meeting.path("communityHost").path("meetingsInfo").first()),
        )
    }

    @Test
    fun `public proof rejects established scalar and nested relationship drift`() {
        val mutations = listOf(
            "UPDATE meetings SET title = '[ДЕМО] изменено' WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE meetings SET address = 'Изменённый адрес' WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE meetings SET source = 'TIMEPAD' WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE meetings SET is_online = true WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
            "UPDATE communities SET name = '[ДЕМО] изменено' WHERE demo_catalog_key = 'closed-beta-demo/community/moscow-meets'",
            "UPDATE tags SET text = '[ДЕМО] изменено' WHERE demo_catalog_key = 'closed-beta-demo/tag/networking'",
            "UPDATE ad_blocks SET action_url = '/unexpected' WHERE demo_catalog_key = 'closed-beta-demo/ad/interests'",
            """
            DELETE FROM meeting_participants
            WHERE meeting_id = (SELECT id FROM meetings WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome')
              AND user_id = (SELECT id FROM users WHERE demo_catalog_key = 'closed-beta-demo/user/02')
            """.trimIndent(),
        )
        mutations.forEach { mutation ->
            resetDatabase()
            jdbcTemplate.execute("SELECT setval('users_id_seq', 1, true)")
            bootstrap()
            jdbcTemplate.update(mutation)
            assertNull(publicProof(), "public proof accepted drift from: $mutation")
        }
    }

    @Test
    fun `snapshot B rejects a committed write after the public probe`() {
        bootstrap()

        val snapshotA = repeatableReadStableProof()
        val publicA = requireNotNull(publicProof())

        jdbcTemplate.update(
            "UPDATE meetings SET date = '28.09.2027' " +
                "WHERE demo_catalog_key = 'closed-beta-demo/meeting/board-games'",
        )

        val snapshotB = repeatableReadStableProof()
        val publicB = publicProof()
        assertNotNull(snapshotA)
        assertNotEquals(snapshotA, snapshotB)
        assertNotEquals(publicA, publicB)
        assertNull(snapshotB)
        assertNull(publicB)
    }

    @Test
    fun `public proof rejects a meeting whose live end has expired`() {
        bootstrap()

        jdbcTemplate.update(
            """
            UPDATE meetings
            SET ends_at = (extract(epoch FROM CURRENT_TIMESTAMP) * 1000)::bigint - 1000
            WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'
            """.trimIndent(),
        )
        assertNull(publicProof())

        jdbcTemplate.update(
            "UPDATE meetings SET ends_at = 1821463200000 " +
                "WHERE demo_catalog_key = 'closed-beta-demo/meeting/welcome'",
        )
        assertNotNull(publicProof())
    }

    private fun bootstrap(confirmReschedule: Boolean = false): dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapResult =
        bootstrapService.bootstrap(
            DemoCatalogBootstrapCommand(
                scheduleAnchorDate = LocalDate.of(2027, 9, 13),
                catalogValidThrough = Instant.parse("2027-09-13T00:00:00Z"),
                confirmReschedule = confirmReschedule,
            ),
        )

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

    private fun recoveryProof(): String? =
        try {
            jdbcTemplate.queryForObject(
                Files.readString(Path.of("scripts", "beta-recovery-database-proof.sql")),
                String::class.java,
            )
        } catch (_: EmptyResultDataAccessException) {
            null
        }

    private fun rootIds(): Map<String, Long> =
        jdbcTemplate.queryForList(
            """
            SELECT demo_catalog_key, id FROM tags WHERE demo_catalog_key LIKE 'closed-beta-demo/%'
            UNION ALL SELECT demo_catalog_key, id FROM users WHERE demo_catalog_key LIKE 'closed-beta-demo/%'
            UNION ALL SELECT demo_catalog_key, id FROM communities WHERE demo_catalog_key LIKE 'closed-beta-demo/%'
            UNION ALL SELECT demo_catalog_key, id FROM meetings WHERE demo_catalog_key LIKE 'closed-beta-demo/%'
            UNION ALL SELECT demo_catalog_key, id FROM ad_blocks WHERE demo_catalog_key LIKE 'closed-beta-demo/%'
            """.trimIndent(),
        ).associate { row ->
            row.getValue("demo_catalog_key").toString() to (row.getValue("id") as Number).toLong()
        }

    private fun scheduleTuples(): List<ScheduleTuple> =
        jdbcTemplate.queryForList(
            """
            SELECT demo_catalog_key, id, time, date, ends_at
            FROM meetings
            WHERE demo_catalog_key LIKE 'closed-beta-demo/%'
            ORDER BY id
            """.trimIndent(),
        ).map { row ->
            ScheduleTuple(
                row.getValue("demo_catalog_key").toString().substringAfterLast('/'),
                (row.getValue("id") as Number).toLong(),
                (row.getValue("time") as Number).toLong(),
                row.getValue("date").toString(),
                (row.getValue("ends_at") as Number).toLong(),
            )
        }

    private fun seedOldAppliedSchedule() {
        listOf(
            ScheduleTuple("welcome", 1L, 1790006400000L, "21.09.2026", 1790013600000L),
            ScheduleTuple("organize-online", 2L, 1790269200000L, "24.09.2026", 1790274600000L),
            ScheduleTuple("board-games", 3L, 1790613000000L, "28.09.2026", 1790622000000L),
            ScheduleTuple("vdnkh-walk", 4L, 1791187200000L, "05.10.2026", 1791194400000L),
            ScheduleTuple("networking-online", 5L, 1791478800000L, "08.10.2026", 1791484200000L),
            ScheduleTuple("public-speaking", 6L, 1791993600000L, "14.10.2026", 1792000800000L),
        ).forEach { tuple ->
            jdbcTemplate.update(
                "UPDATE meetings SET time = ?, date = ?, ends_at = ? WHERE demo_catalog_key = ?",
                tuple.time,
                tuple.date,
                tuple.endsAt,
                "closed-beta-demo/meeting/${tuple.key}",
            )
        }
        jdbcTemplate.update(
            """
            UPDATE demo_catalog_state
            SET manifest_version = '2026-08-15.v1',
                schedule_anchor_date = DATE '2026-09-14',
                catalog_valid_through = TIMESTAMPTZ '2026-09-14T00:00:00Z'
            WHERE catalog_name = 'closed-beta-demo'
            """.trimIndent(),
        )
    }

    private fun fieldNames(node: tools.jackson.databind.JsonNode): Set<String> =
        node.properties().map { it.key }.toSet()

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private data class ScheduleTuple(
        val key: String,
        val id: Long,
        val time: Long,
        val date: String,
        val endsAt: Long,
    )

    private fun repeatableReadStableProof(): String? =
        dataSource.connection.use { connection ->
            connection.autoCommit = false
            connection.transactionIsolation = Connection.TRANSACTION_REPEATABLE_READ
            connection.isReadOnly = true
            try {
                connection.prepareStatement(
                    Files.readString(Path.of("scripts", "test-vps-beta-demo-stable-proof.sql")),
                ).use { statement ->
                    statement.executeQuery().use { resultSet ->
                        if (resultSet.next()) resultSet.getString(1) else null
                    }
                }.also { connection.commit() }
            } catch (error: Throwable) {
                connection.rollback()
                throw error
            }
        }
}
