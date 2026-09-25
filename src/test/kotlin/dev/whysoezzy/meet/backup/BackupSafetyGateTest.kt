package dev.whysoezzy.meet.backup

import dev.whysoezzy.meet.api.error.BackupSafetyBlockedException
import dev.whysoezzy.meet.config.BackupSafetyProperties
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import tools.jackson.module.kotlin.jacksonObjectMapper
import java.nio.file.Files
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset

class BackupSafetyGateTest {
    @Test
    fun `admits healthy observation while capture RPO breach remains a monitoring concern`() {
        val directory = Files.createTempDirectory("backup-safety-gate")
        val path = directory.resolve("status.json")
        Files.writeString(path, status(observedAt = 1_000_000, captureAt = 800_000, verifiedAt = 999_000))
        val properties = BackupSafetyProperties(
            enabled = true,
            enrolled = true,
            environment = "closed-beta",
            statusPath = path.toString(),
        )
        BackupSafetyGate(
            properties,
            BackupSafetySnapshotReader(jacksonObjectMapper(), properties),
            Clock.fixed(Instant.ofEpochSecond(1_000_000), ZoneOffset.UTC),
        ).requireAdmitted("test")
    }

    @Test
    fun `blocks stale verified capture and stale local observation independently`() {
        val directory = Files.createTempDirectory("backup-safety-gate")
        val path = directory.resolve("status.json")
        val properties = BackupSafetyProperties(
            enabled = true,
            enrolled = true,
            environment = "closed-beta",
            statusPath = path.toString(),
        )
        Files.writeString(path, status(observedAt = 1_000_000, captureAt = 1_000_000, verifiedAt = 1_000_000 - 14 * 24 * 60 * 60))
        assertThrows<BackupSafetyBlockedException> {
            BackupSafetyGate(
                properties,
                BackupSafetySnapshotReader(jacksonObjectMapper(), properties),
                Clock.fixed(Instant.ofEpochSecond(1_000_000), ZoneOffset.UTC),
            ).requireAdmitted("test")
        }
        Files.writeString(path, status(observedAt = 1_000_000 - 1801, captureAt = 1_000_000, verifiedAt = 1_000_000))
        assertThrows<BackupSafetyBlockedException> {
            BackupSafetyGate(
                properties,
                BackupSafetySnapshotReader(jacksonObjectMapper(), properties),
                Clock.fixed(Instant.ofEpochSecond(1_000_000), ZoneOffset.UTC),
            ).requireAdmitted("test")
        }
    }

    private fun status(observedAt: Long, captureAt: Long, verifiedAt: Long): String {
        val digest = "a".repeat(64)
        return """{"authorityDigest":"$digest","authorityGeneration":1,"capture":{"capturedAt":$captureAt,"id":"point-1","state":"VALID"},"environment":"closed-beta","observedAt":$observedAt,"schema":"meet-backend/beta-backup-status/v1","verified":{"capturedAt":$verifiedAt,"id":"point-1","state":"VALID"}}"""
    }
}
