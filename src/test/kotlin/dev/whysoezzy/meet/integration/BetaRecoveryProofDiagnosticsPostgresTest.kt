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

class BetaRecoveryProofDiagnosticsPostgresTest : IntegrationTestSupport() {
    private val objectMapper = ObjectMapper()

    @Autowired
    private lateinit var bootstrapService: DemoCatalogBootstrapService

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @Test
    fun `diagnose empty V11 proof validity`() {
        failWithDiagnostics()
    }

    @Test
    fun `diagnose populated demo V11 proof validity`() {
        bootstrapService.bootstrap(
            DemoCatalogBootstrapCommand(
                LocalDate.of(2099, 1, 1),
                Instant.parse("2098-12-01T00:00:00Z"),
            ),
        )
        failWithDiagnostics()
    }

    private fun failWithDiagnostics(): Nothing {
        val diagnosticSql = Files.readString(Path.of("scripts", "beta-recovery-database-proof.sql"))
            .replace(
                "SELECT proof::text\nFROM proof_document\nWHERE (SELECT valid FROM validity_summary);",
                "SELECT jsonb_build_object('proof', proof, 'validity', (SELECT row_to_json(validity_summary)))::text FROM proof_document;",
            )
        val diagnostic = requireNotNull(jdbcTemplate.queryForObject(diagnosticSql, String::class.java))
        error(objectMapper.readTree(diagnostic).toPrettyString())
    }
}
