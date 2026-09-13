package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.parseFid
import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.service.push.PushInstallationService
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class PushInstallationLifecyclePostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var installationService: PushInstallationService

    @Autowired
    private lateinit var installationStore: dev.whysoezzy.meet.service.push.PushInstallationStore

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `same owner heartbeat preserves id and transfer permanently retires old row`() {
        val fixture = fixture()
        val first = installationService.register(fixture.alice.id!!, parseFid("fid-alice"))
        val heartbeat = installationService.register(fixture.alice.id!!, parseFid("fid-alice"))
        assertEquals(first.installation.id, heartbeat.installation.id)
        assertEquals(1L, heartbeat.installation.registrationVersion)

        val transferred = installationService.register(fixture.bob.id!!, parseFid("fid-alice"))
        assertNotEquals(first.installation.id, transferred.installation.id)
        assertEquals("TRANSFERRED", jdbcTemplate.queryForObject(
            "SELECT status FROM push_installations WHERE id = ?",
            String::class.java,
            first.installation.id,
        ))
        assertEquals("ACTIVE", transferred.installation.status.name)
    }

    @Test
    fun `concurrent owners have one active FID and one permanently transferred source`() {
        val fixture = fixture()
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val futures = listOf(fixture.alice.id!!, fixture.bob.id!!).map { userId ->
                executor.submit {
                    assertTrue(start.await(10, TimeUnit.SECONDS))
                    installationService.register(userId, parseFid("fid-owner-race"))
                }
            }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }

            assertEquals(
                1L,
                jdbcTemplate.queryForObject(
                    "SELECT COUNT(*) FROM push_installations WHERE fid = 'fid-owner-race' AND status = 'ACTIVE'",
                    Long::class.java,
                ),
            )
            assertEquals(
                1L,
                jdbcTemplate.queryForObject(
                    "SELECT COUNT(*) FROM push_installations WHERE status = 'TRANSFERRED'",
                    Long::class.java,
                ),
            )
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `expiry uses the exact thirty five day boundary and preserves a fresh concurrent heartbeat`() {
        val fixture = fixture()
        val first = installationService.register(fixture.alice.id!!, parseFid("fid-expiry-boundary"))
        val boundary = Instant.parse("2026-09-12T00:00:00Z")
        jdbcTemplate.update(
            "UPDATE push_installations SET last_seen_at = ?, updated_at = ? WHERE id = ?",
            java.sql.Timestamp.from(boundary.minus(35, ChronoUnit.DAYS)),
            java.sql.Timestamp.from(boundary.minus(35, ChronoUnit.DAYS)),
            first.installation.id,
        )
        assertEquals(1, installationStore.expireStale(boundary, 100))
        assertEquals(
            "EXPIRED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE id = ?",
                String::class.java,
                first.installation.id,
            ),
        )

        val fresh = installationService.register(fixture.alice.id!!, parseFid("fid-fresh-boundary"))
        jdbcTemplate.update(
            "UPDATE push_installations SET last_seen_at = ?, updated_at = ? WHERE id = ?",
            java.sql.Timestamp.from(boundary.minus(35, ChronoUnit.DAYS).plusMillis(1)),
            java.sql.Timestamp.from(boundary.minus(35, ChronoUnit.DAYS).plusMillis(1)),
            fresh.installation.id,
        )
        assertEquals(0, installationStore.expireStale(boundary, 100))
        assertEquals(
            "ACTIVE",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE id = ?",
                String::class.java,
                fresh.installation.id,
            ),
        )
    }

    @Test
    fun `unregister is idempotent for the owner and does not erase transferred retirement`() {
        val fixture = fixture()
        val first = installationService.register(fixture.alice.id!!, parseFid("fid-delete-race"))
        installationService.unregister(fixture.alice.id!!, first.installation.id)
        installationService.unregister(fixture.alice.id!!, first.installation.id)
        assertEquals(
            "UNREGISTERED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE id = ?",
                String::class.java,
                first.installation.id,
            ),
        )

        val transferred = installationService.register(fixture.alice.id!!, parseFid("fid-transferred-delete"))
        installationService.register(fixture.bob.id!!, parseFid("fid-transferred-delete"))
        assertFailsWith<NotFoundException> {
            installationService.unregister(fixture.alice.id!!, transferred.installation.id)
        }
        assertEquals(
            "TRANSFERRED",
            jdbcTemplate.queryForObject(
                "SELECT status FROM push_installations WHERE id = ?",
                String::class.java,
                transferred.installation.id,
            ),
        )
    }

    @Test
    fun `concurrent unregister and heartbeat preserve a single coherent active owner`() {
        val fixture = fixture()
        val userId = requireNotNull(fixture.alice.id)
        val installation = installationService.register(userId, parseFid("fid-unregister-heartbeat"))
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val unregister = executor.submit {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                installationService.unregister(userId, installation.installation.id)
            }
            val heartbeat = executor.submit {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                installationService.register(userId, parseFid("fid-unregister-heartbeat"))
            }
            start.countDown()
            unregister.get(10, TimeUnit.SECONDS)
            heartbeat.get(10, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
        }

        val activeCount = jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM push_installations WHERE user_id = ? AND fid = 'fid-unregister-heartbeat' AND status = 'ACTIVE'",
            Long::class.java,
            userId,
        )!!
        assertTrue(activeCount in 0..1)
        assertTrue(
            jdbcTemplate.queryForList(
                "SELECT status FROM push_installations WHERE user_id = ?",
                String::class.java,
                userId,
            ).all { it in setOf("ACTIVE", "UNREGISTERED") },
        )
    }

    @Test
    fun `concurrent unregister and same-FID registration preserve lifecycle constraints`() {
        val fixture = fixture()
        val userId = requireNotNull(fixture.alice.id)
        val fid = parseFid("fid-delete-register-race")
        installationService.register(userId, fid)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val unregister = executor.submit {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                installationService.unregister(
                    userId,
                    requireNotNull(
                        jdbcTemplate.queryForObject(
                            "SELECT id FROM push_installations WHERE user_id = ? AND fid = ?",
                            java.util.UUID::class.java,
                            userId,
                            fid.value,
                        ),
                    ),
                )
            }
            val register = executor.submit {
                assertTrue(start.await(10, TimeUnit.SECONDS))
                installationService.register(userId, fid)
            }
            start.countDown()
            unregister.get(10, TimeUnit.SECONDS)
            register.get(10, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
        }

        assertTrue(
            jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM push_installations WHERE fid = ? AND status = 'ACTIVE'",
                Long::class.java,
                fid.value,
            )!! <= 1,
        )
    }
}
