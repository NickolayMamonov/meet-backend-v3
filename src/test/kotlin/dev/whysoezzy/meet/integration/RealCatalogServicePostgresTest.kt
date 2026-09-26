package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.catalog.RealCatalogApplyRequest
import dev.whysoezzy.meet.catalog.RealCatalogAttestationVerifier
import dev.whysoezzy.meet.catalog.RealCatalogPreviewRequest
import dev.whysoezzy.meet.catalog.RealCatalogService
import dev.whysoezzy.meet.config.RealCatalogProperties
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Primary
import org.springframework.test.context.TestPropertySource
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

@TestPropertySource(
    properties = [
        "app.real-catalog.enabled=true",
        "app.real-catalog.target-environment=test-postgres",
        "app.real-catalog.approved-media-hosts=example.test",
        "app.real-catalog.attestation-secret=test-real-catalog-attestation-secret-32-bytes",
    ],
)
@org.springframework.context.annotation.Import(RealCatalogServicePostgresTest.FixedClockConfiguration::class)
class RealCatalogServicePostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var service: RealCatalogService
    @Autowired
    private lateinit var loader: dev.whysoezzy.meet.catalog.RealCatalogManifestLoader
    @Autowired
    private lateinit var properties: RealCatalogProperties

    @BeforeEach
    fun clear() = resetDatabase()

    @Test
    fun `preview includes the earliest item and field provenance cutoff`() {
        val loaded = loader.load("synthetic-v1")
        val response = service.preview(RealCatalogPreviewRequest("synthetic-v1", loaded.digest))

        assertTrue(response.changed)
        assertEquals("closed-beta-real", response.catalogKey)
        assertEquals("2026-09-26T00:00:00Z", response.discoverableUntil)
        assertEquals(1, response.activeCommunities)
        assertEquals(1, response.activeMeetings)
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM real_catalog_state", Long::class.java))
    }

    @Test
    fun `apply requires bound attestations and replay is idempotent`() {
        val loaded = loader.load("synthetic-v1")
        val invalid = RealCatalogApplyRequest(
            revision = "synthetic-v1",
            digest = loaded.digest,
            contentApprovalRef = "content",
            mutationAuthorizationRef = "mutation",
            recoveryPointRef = "recovery",
        )
        assertFailsWith<ConflictException> { service.apply(invalid) }
        assertEquals(0, jdbcTemplate.queryForObject("SELECT count(*) FROM real_catalog_state", Long::class.java))

        val recoveryPoint = "recovery-point-1"
        val proofDigest = "d".repeat(64)
        val request = RealCatalogApplyRequest(
            revision = "synthetic-v1",
            digest = loaded.digest,
            contentApprovalRef = attestation(RealCatalogAttestationVerifier.CONTENT, loaded.digest),
            mutationAuthorizationRef = attestation(
                RealCatalogAttestationVerifier.MUTATION,
                loaded.digest,
                recoveryPoint,
                proofDigest,
            ),
            recoveryPointRef = attestation(
                RealCatalogAttestationVerifier.RECOVERY,
                loaded.digest,
                recoveryPoint,
                proofDigest,
            ),
        )
        val applied = service.apply(request)
        val replay = service.apply(request.copy(expectedGeneration = 99))

        assertTrue(applied.changed)
        assertFalse(replay.changed)
        assertEquals(1L, replay.generation)
        assertEquals(1, jdbcTemplate.queryForObject("SELECT count(*) FROM real_catalog_revisions", Long::class.java))
        assertEquals(1, jdbcTemplate.queryForObject("SELECT count(*) FROM real_catalog_state", Long::class.java))
        assertEquals(
            1,
            jdbcTemplate.queryForObject(
                "SELECT count(*) FROM meetings WHERE real_catalog_key = 'closed-beta-real'",
                Long::class.java,
            ),
        )
        assertEquals("test-postgres", properties.targetEnvironment)
    }

    private fun attestation(
        kind: String,
        digest: String,
        recoveryPoint: String = "-",
        proofDigest: String = "-",
    ): String {
        val expiresAt = Instant.parse("2026-09-30T00:00:00Z").epochSecond
        val fields = listOf(
            kind,
            "closed-beta-real",
            digest,
            "INITIAL",
            properties.targetEnvironment,
            recoveryPoint,
            if (recoveryPoint == "-") "-" else RealCatalogAttestationVerifier.RECOVERY_PROOF_SCHEMA,
            proofDigest,
            expiresAt.toString(),
        ).map { Base64.getUrlEncoder().withoutPadding().encodeToString(it.toByteArray(StandardCharsets.UTF_8)) }
        val payload = (listOf(RealCatalogAttestationVerifier.PREFIX) + fields).joinToString(".")
        val signature = Mac.getInstance("HmacSHA256").apply {
            init(
                SecretKeySpec(
                    "test-real-catalog-attestation-secret-32-bytes".toByteArray(StandardCharsets.UTF_8),
                    "HmacSHA256",
                ),
            )
        }.doFinal(payload.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "$payload.$signature"
    }

    @TestConfiguration(proxyBeanMethods = false)
    class FixedClockConfiguration {
        @Bean
        @Primary
        fun realCatalogTestClock(): Clock =
            Clock.fixed(Instant.parse("2026-09-25T12:00:00Z"), ZoneOffset.UTC)
    }
}
