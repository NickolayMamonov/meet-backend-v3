package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.service.push.parseFid
import dev.whysoezzy.meet.service.push.PushInstallationService
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class PushInstallationLifecyclePostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var installationService: PushInstallationService

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
}
