package dev.whysoezzy.meet.backup

import dev.whysoezzy.meet.api.error.BackupSafetyBlockedException
import dev.whysoezzy.meet.config.BackupSafetyProperties
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.Assumptions.assumeTrue
import tools.jackson.module.kotlin.jacksonObjectMapper
import java.nio.file.Files
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.security.MessageDigest

class BackupSafetyGateTest {
    @Test
    fun `admits healthy observation while capture RPO breach remains a monitoring concern`() {
        assumeTrue(posixAttributesSupported())
        val directory = Files.createTempDirectory("backup-safety-gate")
        val path = directory.resolve("status.json")
        Files.writeString(path, status(observedAt = 1_000_000, captureAt = 800_000, verifiedAt = 999_000))
        writeWatermark(path, 1, 1_000_000)
        val properties = propertiesFor(directory, path)
        BackupSafetyGate(
            properties,
            BackupSafetySnapshotReader(jacksonObjectMapper(), properties),
            Clock.fixed(Instant.ofEpochSecond(1_000_000), ZoneOffset.UTC),
        ).requireAdmitted("test")
    }

    @Test
    fun `blocks stale verified capture and stale local observation independently`() {
        assumeTrue(posixAttributesSupported())
        val directory = Files.createTempDirectory("backup-safety-gate")
        val path = directory.resolve("status.json")
        val properties = propertiesFor(directory, path)
        Files.writeString(path, status(observedAt = 1_000_000, captureAt = 1_000_000, verifiedAt = 1_000_000 - 14 * 24 * 60 * 60))
        writeWatermark(path, 1, 1_000_000)
        assertThrows<BackupSafetyBlockedException> {
            BackupSafetyGate(
                properties,
                BackupSafetySnapshotReader(jacksonObjectMapper(), properties),
                Clock.fixed(Instant.ofEpochSecond(1_000_000), ZoneOffset.UTC),
            ).requireAdmitted("test")
        }
        Files.writeString(path, status(observedAt = 1_000_000 - 1801, captureAt = 1_000_000, verifiedAt = 1_000_000))
        writeWatermark(path, 1, 1_000_000 - 1801)
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

    private fun writeWatermark(path: java.nio.file.Path, generation: Long, observedAt: Long) {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(Files.readAllBytes(path))
            .joinToString("") { "%02x".format(it) }
        Files.writeString(
            path.parent.resolve("watermark.json"),
            """{"authorityGeneration":$generation,"observedAt":$observedAt,"schema":"meet-backend/beta-backup-watermark/v1","statusDigest":"$digest"}""",
        )
    }

    private fun propertiesFor(
        directory: java.nio.file.Path,
        path: java.nio.file.Path,
    ): BackupSafetyProperties {
        val attrs = runCatching {
            Files.readAttributes(directory, "unix:dev,ino,mode,uid,gid")
        }.getOrNull() ?: return BackupSafetyProperties(
            enabled = true,
            enrolled = false,
            environment = "closed-beta",
            statusPath = path.toString(),
        )
        val mode = (attrs["mode"] as Number).toLong() and 0xFFF
        val identity = listOf("dev", "ino").map { (attrs[it] as Number).toLong() }
            .plus(mode)
            .plus(listOf("uid", "gid").map { (attrs[it] as Number).toLong() })
            .joinToString(":")
        return BackupSafetyProperties(
            enabled = true,
            enrolled = true,
            environment = "closed-beta",
            statusPath = path.toString(),
            controlRootMode = mode.toString(8),
            controlRootUid = (attrs["uid"] as Number).toLong(),
            controlRootGid = (attrs["gid"] as Number).toLong(),
            mountIdentity = identity,
        )
    }

    private fun posixAttributesSupported(): Boolean =
        runCatching {
            Files.readAttributes(
                Files.createTempDirectory("backup-safety-probe"),
                "unix:dev,ino,mode,uid,gid",
            )
        }.isSuccess
}
