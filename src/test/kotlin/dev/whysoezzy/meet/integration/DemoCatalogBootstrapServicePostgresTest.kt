package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapCommand
import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapService
import dev.whysoezzy.meet.demo.catalog.DemoCatalogFailureInjector
import dev.whysoezzy.meet.demo.catalog.DemoCatalogStateRepository
import dev.whysoezzy.meet.domain.entity.User
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.reset
import dev.whysoezzy.meet.api.error.ConflictException
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.test.context.bean.override.mockito.MockitoBean
import java.time.Instant
import java.time.LocalDate
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DemoCatalogBootstrapServicePostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var service: DemoCatalogBootstrapService

    @Autowired
    private lateinit var state: DemoCatalogStateRepository

    @MockitoBean
    private lateinit var failureInjector: DemoCatalogFailureInjector

    private val command = DemoCatalogBootstrapCommand(
        LocalDate.of(2099, 1, 1),
        Instant.parse("2098-12-01T00:00:00Z"),
    )

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `clean apply and identical rerun are complete and idempotent`() {
        val first = service.bootstrap(command)
        assertEquals(6, first.roots.tags.created)
        assertEquals(6, first.roots.users.created)
        assertEquals(3, first.roots.communities.created)
        assertEquals(6, first.roots.meetings.created)
        assertEquals(3, first.roots.adBlocks.created)
        assertEquals(12, first.relationships.userInterests.added)
        assertEquals(7, first.relationships.communityTags.added)
        assertEquals(9, first.relationships.communitySubscribers.added)
        assertEquals(12, first.relationships.meetingTags.added)
        assertEquals(18, first.relationships.meetingParticipants.added)
        assertEquals(6, first.relationships.meetingPersonHosts.added)
        assertEquals(6, first.relationships.meetingCommunityHosts.added)
        assertEquals(3, first.relationships.adBlockCommunities.added)
        assertEquals(4, first.relationships.adBlockUsers.added)
        assertEquals(1, state.count())
        assertEquals(6, users.count())
        assertEquals(3, communities.count())
        assertEquals(6, meetings.count())
        assertEquals(6, tags.count())
        assertEquals(3, adBlocks.count())
        assertTrue(users.findAll().filter { it.demoCatalogKey != null }.all { !it.notificationsEnabled })

        val ids = meetings.findAll().associate { it.demoCatalogKey to it.id }
        val second = service.bootstrap(command)
        assertEquals(6, second.roots.tags.unchanged)
        assertEquals(6, second.roots.users.unchanged)
        assertEquals(3, second.roots.communities.unchanged)
        assertEquals(6, second.roots.meetings.unchanged)
        assertEquals(3, second.roots.adBlocks.unchanged)
        assertEquals(12, second.relationships.userInterests.unchanged)
        assertEquals(18, second.relationships.meetingParticipants.unchanged)
        assertTrue(meetings.findAll().all { ids[it.demoCatalogKey] == it.id })
    }

    @Test
    fun `real rows and authentication storage remain untouched`() {
        val real = users.save(dev.whysoezzy.meet.domain.entity.User("Real", "User", "+15550000099"))
        val realMeeting = meetings.save(
            dev.whysoezzy.meet.domain.entity.Meeting(
                "Real meeting",
                "Not demo",
                "https://example.invalid/real.png",
                4_102_444_800_000,
                "01.01.2100",
                "Moscow",
                55.75,
                37.61,
            ),
        )
        service.bootstrap(command)
        assertEquals(real.id, users.findById(requireNotNull(real.id)).orElseThrow().id)
        assertEquals(realMeeting.id, meetings.findById(requireNotNull(realMeeting.id)).orElseThrow().id)
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM auth_identities", Long::class.java))
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM refresh_tokens", Long::class.java))
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM otp_codes", Long::class.java))
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM user_social_media", Long::class.java))
    }

    @ParameterizedTest
    @ValueSource(strings = ["phone", "fcm", "identity", "refresh", "otp", "social", "role", "deletedAt", "authVersion"])
    fun `forbidden synthetic-user contamination fails before a second write`(kind: String) {
        service.bootstrap(command)
        val demoUser = users.findAll().first { it.demoCatalogKey == "closed-beta-demo/user/01" }
        val userId = requireNotNull(demoUser.id)
        when (kind) {
            "phone" -> jdbcTemplate.update("UPDATE users SET phone = ? WHERE id = ?", "+15551112222", userId)
            "fcm" -> jdbcTemplate.update("UPDATE users SET fcm_token = ? WHERE id = ?", "contaminated", userId)
            "identity" -> jdbcTemplate.update(
                "INSERT INTO auth_identities(user_id, type, normalized_identifier) VALUES (?, 'EMAIL', ?)",
                userId,
                "contaminated@example.invalid",
            )
            "refresh" -> jdbcTemplate.update(
                "INSERT INTO refresh_tokens(user_id, token_hash, expires_at) VALUES (?, ?, ?)",
                userId,
                "a".repeat(64),
                java.time.LocalDateTime.now().plusDays(1),
            )
            "otp" -> {
                jdbcTemplate.update("UPDATE users SET phone = ? WHERE id = ?", "+15551113333", userId)
                jdbcTemplate.update(
                    """
                    INSERT INTO otp_codes(identifier, channel, code_hash, hash_salt, hash_key_id, status, max_attempts, expires_at)
                    VALUES (?, 'PHONE', ?, ?, 'test', 'PENDING', 5, CURRENT_TIMESTAMP + INTERVAL '1 hour')
                    """.trimIndent(),
                    "+15551113333",
                    ByteArray(32),
                    ByteArray(16),
                )
            }
            "social" -> jdbcTemplate.update(
                "INSERT INTO user_social_media(user_id, platform, username) VALUES (?, 'TELEGRAM', 'contaminated')",
                userId,
            )
            "role" -> jdbcTemplate.update("UPDATE users SET role = 'USER' WHERE id = ?", userId)
            "deletedAt" -> jdbcTemplate.update("UPDATE users SET deleted_at = CURRENT_TIMESTAMP WHERE id = ?", userId)
            "authVersion" -> jdbcTemplate.update("UPDATE users SET auth_version = 1 WHERE id = ?", userId)
        }
        org.junit.jupiter.api.assertThrows<ConflictException> { service.bootstrap(command) }
        assertEquals(1, state.count())
        assertEquals(6, users.count())
    }

    @ParameterizedTest
    @ValueSource(strings = ["current-email", "desired-email"])
    fun `email OTP history conflicts before writes and preserves auth state`(kind: String) {
        service.bootstrap(command)
        val demoUser = users.findAll().first { it.demoCatalogKey == "closed-beta-demo/user/01" }
        val userId = requireNotNull(demoUser.id)
        val identifier = if (kind == "current-email") {
            "current-beta-email@example.invalid"
        } else {
            "beta-demo-person-01@example.invalid"
        }
        if (kind == "current-email") {
            jdbcTemplate.update("UPDATE users SET email = ? WHERE id = ?", identifier, userId)
        }
        jdbcTemplate.update(
            """
            INSERT INTO otp_codes(identifier, channel, code_hash, hash_salt, hash_key_id, status, max_attempts, expires_at)
            VALUES (?, 'EMAIL', ?, ?, 'test', 'PENDING', 5, CURRENT_TIMESTAMP + INTERVAL '1 hour')
            """.trimIndent(),
            identifier,
            ByteArray(32),
            ByteArray(16),
        )

        assertThrows<ConflictException> { service.bootstrap(command) }

        val persisted = users.findById(userId).orElseThrow()
        assertEquals(identifier, persisted.email)
        assertFalse(persisted.notificationsEnabled)
        assertEquals(1, state.count())
        assertEquals(6, users.count())
        assertEquals(1, jdbcTemplate.queryForObject("SELECT count(*) FROM otp_codes", Long::class.java))
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM auth_identities", Long::class.java))
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM refresh_tokens", Long::class.java))
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM user_social_media", Long::class.java))
    }

    @Test
    fun `desired email OTP history conflicts on a clean database before any catalog write`() {
        jdbcTemplate.update(
            """
            INSERT INTO otp_codes(identifier, channel, code_hash, hash_salt, hash_key_id, status, max_attempts, expires_at)
            VALUES (?, 'EMAIL', ?, ?, 'test', 'PENDING', 5, CURRENT_TIMESTAMP + INTERVAL '1 hour')
            """.trimIndent(),
            " BETA-DEMO-PERSON-01@EXAMPLE.INVALID ",
            ByteArray(32),
            ByteArray(16),
        )

        assertThrows<ConflictException> { service.bootstrap(command) }

        assertEquals(0, state.count())
        assertEquals(0, users.count())
        assertEquals(0, tags.count())
        assertEquals(0, communities.count())
        assertEquals(0, meetings.count())
        assertEquals(0, adBlocks.count())
        assertEquals(1, jdbcTemplate.queryForObject("SELECT count(*) FROM otp_codes", Long::class.java))
    }

    @Test
    fun `injected failure rolls back roots edges state and auth storage after context clear`() {
        service.bootstrap(command)
        val realUser = users.save(User("Real", "Member", "+15550000098", email = "real@example.test"))
        val realUserId = requireNotNull(realUser.id)
        jdbcTemplate.update(
            "INSERT INTO auth_identities(user_id, type, normalized_identifier) VALUES (?, 'EMAIL', ?)",
            realUserId,
            "real@example.test",
        )
        jdbcTemplate.update(
            """
            INSERT INTO refresh_tokens(user_id, token_hash, expires_at, auth_version)
            VALUES (?, ?, CURRENT_TIMESTAMP + INTERVAL '1 day', 0)
            """.trimIndent(),
            realUserId,
            "b".repeat(64),
        )
        jdbcTemplate.update(
            """
            INSERT INTO otp_codes(identifier, channel, code_hash, hash_salt, hash_key_id, status, max_attempts, expires_at)
            VALUES (?, 'EMAIL', ?, ?, 'test', 'PENDING', 5, CURRENT_TIMESTAMP + INTERVAL '1 hour')
            """.trimIndent(),
            "real@example.test",
            ByteArray(32) { 1 },
            ByteArray(16) { 2 },
        )
        jdbcTemplate.update(
            "INSERT INTO user_social_media(user_id, platform, username) VALUES (?, 'TELEGRAM', ?)",
            realUserId,
            "real-member",
        )
        val before = databaseSnapshot()

        doThrow(IllegalStateException("injected demo catalog failure"))
            .`when`(failureInjector)
            .afterFlushBeforeStateSave()

        try {
            assertThrows<IllegalStateException> { service.bootstrap(command) }
        } finally {
            reset(failureInjector)
        }
        entityManager.clear()

        assertEquals(before, databaseSnapshot())
    }

    @Test
    fun `PHONE identity with a matching email-shaped identifier is not an email collision`() {
        service.bootstrap(command)
        val real = users.save(
            dev.whysoezzy.meet.domain.entity.User(
                "Real",
                "Phone",
                phone = null,
                email = "real@example.test",
            ),
        )
        jdbcTemplate.update(
            "INSERT INTO auth_identities(user_id, type, normalized_identifier) VALUES (?, 'PHONE', ?)",
            requireNotNull(real.id),
            "beta-demo-person-01@example.invalid",
        )

        val result = service.bootstrap(command)

        assertEquals(6, result.roots.users.unchanged)
        assertEquals(1, jdbcTemplate.queryForObject("SELECT count(*) FROM auth_identities WHERE type = 'PHONE'", Long::class.java))
    }

    @Autowired
    private lateinit var entityManager: jakarta.persistence.EntityManager

    private fun databaseSnapshot(): Map<String, List<String>> =
        snapshotTables.associateWith { table ->
            jdbcTemplate.queryForList("SELECT * FROM $table")
                .map { row ->
                    row.entries
                        .sortedBy { it.key }
                        .joinToString("|") { (column, value) -> "$column=${snapshotValue(value)}" }
                }
                .sorted()
        }

    private fun snapshotValue(value: Any?): String = when (value) {
        null -> "<null>"
        is ByteArray -> value.joinToString(",") { it.toUByte().toString() }
        else -> value.toString()
    }

    private companion object {
        val snapshotTables = listOf(
            "tags",
            "users",
            "communities",
            "meetings",
            "ad_blocks",
            "user_interests",
            "community_tags",
            "community_subscribers",
            "meeting_tags",
            "meeting_participants",
            "ad_block_communities",
            "ad_block_users",
            "demo_catalog_state",
            "auth_identities",
            "refresh_tokens",
            "otp_codes",
            "user_social_media",
        )
    }
}
