package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapCommand
import dev.whysoezzy.meet.demo.catalog.DemoCatalogBootstrapService
import dev.whysoezzy.meet.demo.catalog.DemoCatalogStateRepository
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import dev.whysoezzy.meet.api.error.ConflictException
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import java.time.LocalDate
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DemoCatalogBootstrapServicePostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var service: DemoCatalogBootstrapService

    @Autowired
    private lateinit var state: DemoCatalogStateRepository

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
}
