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
                """
                SELECT jsonb_build_object(
                    'proof', proof,
                    'validity', (SELECT row_to_json(v) FROM validity_summary v),
                    'indexes', COALESCE((
                        SELECT jsonb_agg(to_jsonb(index_row) ORDER BY index_row.index_name)
                        FROM (
                            SELECT index_class.relname AS index_name,
                                   index_row.indisunique AS unique_index,
                                   pg_get_expr(index_row.indpred, index_row.indrelid) AS predicate,
                                   (
                                       SELECT array_agg(
                                           pg_get_indexdef(index_row.indexrelid, key_number, true)
                                           ORDER BY key_number
                                       )
                                       FROM generate_series(1, index_row.indnkeyatts) key_number
                                   ) AS key_columns
                            FROM pg_class index_class
                            JOIN pg_namespace namespace
                              ON namespace.oid = index_class.relnamespace
                             AND namespace.nspname = current_schema()
                            JOIN pg_index index_row
                              ON index_row.indexrelid = index_class.oid
                            WHERE index_class.relname IN (
                                'uq_meetings_source_external',
                                'uq_refresh_tokens_token_hash',
                                'uq_otp_codes_active',
                                'idx_otp_codes_expires_id',
                                'uq_users_demo_catalog_key',
                                'uq_communities_demo_catalog_key',
                                'uq_meetings_demo_catalog_key',
                                'uq_tags_demo_catalog_key',
                                'uq_ad_blocks_demo_catalog_key',
                                'uq_meetings_real_catalog_item',
                                'uq_communities_real_catalog_item',
                                'idx_real_catalog_state_cutoff',
                                'idx_meetings_real_catalog_discovery',
                                'idx_communities_real_catalog_discovery'
                            )
                        ) index_row
                    ), '[]'::jsonb)
                )::text
                FROM proof_document;
                """.trimIndent(),
            )
        val diagnostic = requireNotNull(jdbcTemplate.queryForObject(diagnosticSql, String::class.java))
        error(objectMapper.readTree(diagnostic).toPrettyString())
    }
}
