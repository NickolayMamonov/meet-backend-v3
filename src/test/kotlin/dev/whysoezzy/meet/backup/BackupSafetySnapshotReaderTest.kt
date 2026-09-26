package dev.whysoezzy.meet.backup

import dev.whysoezzy.meet.config.BackupSafetyProperties
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import tools.jackson.module.kotlin.jacksonObjectMapper
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.test.assertEquals

class BackupSafetySnapshotReaderTest {
    @Test
    fun `reads strict bounded status and preserves original evidence times`() {
        val directory = Files.createTempDirectory("backup-safety-reader")
        val path = directory.resolve("status.json")
        val digest = "a".repeat(64)
        Files.writeString(
            path,
            """{"authorityDigest":"$digest","authorityGeneration":4,"capture":{"capturedAt":1000,"id":"point-1","state":"VALID"},"environment":"closed-beta","observedAt":1100,"schema":"meet-backend/beta-backup-status/v1","verified":{"capturedAt":900,"id":"point-0","state":"VALID"}}""",
        )
        val statusDigest = MessageDigest.getInstance("SHA-256")
            .digest(Files.readAllBytes(path))
            .joinToString("") { "%02x".format(it) }
        Files.writeString(
            directory.resolve("watermark.json"),
            """{"authorityGeneration":4,"observedAt":1100,"schema":"meet-backend/beta-backup-watermark/v1","statusDigest":"$statusDigest"}""",
        )
        val reader = BackupSafetySnapshotReader(
            jacksonObjectMapper(),
            BackupSafetyProperties(environment = "closed-beta", statusPath = path.toString()),
        )

        val snapshot = reader.read()

        assertEquals(1000, snapshot.capture.capturedAtEpochSeconds)
        assertEquals(900, snapshot.verified.capturedAtEpochSeconds)
        assertEquals(4, snapshot.authorityGeneration)
    }

    @Test
    fun `rejects an enrolled replacement mount with a changed device or inode`() {
        val directory = Files.createTempDirectory("backup-safety-mount")
        val path = directory.resolve("status.json")
        val attrs = runCatching {
            Files.readAttributes(directory, "unix:dev,ino,mode,uid,gid")
        }.getOrNull() ?: return
        val mode = (attrs["mode"] as Number).toLong() and 0xFFF
        val identity = listOf("dev", "ino").map { (attrs[it] as Number).toLong() }
            .plus(mode)
            .plus(listOf("uid", "gid").map { (attrs[it] as Number).toLong() })
            .joinToString(":")
        val properties = BackupSafetyProperties(
            enabled = true,
            enrolled = true,
            environment = "closed-beta",
            statusPath = path.toString(),
            controlRootMode = mode.toString(8),
            controlRootUid = (attrs["uid"] as Number).toLong(),
            controlRootGid = (attrs["gid"] as Number).toLong(),
            mountIdentity = identity,
        )
        val digest = "a".repeat(64)
        val status = """{"authorityDigest":"$digest","authorityGeneration":1,"capture":{"capturedAt":1000,"id":"point-1","state":"VALID"},"environment":"closed-beta","observedAt":1100,"schema":"meet-backend/beta-backup-status/v1","verified":{"capturedAt":1000,"id":"point-1","state":"VALID"}}"""
        Files.writeString(path, status)
        val statusDigest = MessageDigest.getInstance("SHA-256")
            .digest(status.toByteArray())
            .joinToString("") { "%02x".format(it) }
        Files.writeString(
            directory.resolve("watermark.json"),
            """{"authorityGeneration":1,"observedAt":1100,"schema":"meet-backend/beta-backup-watermark/v1","statusDigest":"$statusDigest"}""",
        )
        Files.move(directory, directory.resolveSibling("${directory.fileName}-moved"))
        val replacement = Files.createTempDirectory("backup-safety-mount-replacement")
        Files.writeString(replacement.resolve("status.json"), status)
        Files.writeString(
            replacement.resolve("watermark.json"),
            """{"authorityGeneration":1,"observedAt":1100,"schema":"meet-backend/beta-backup-watermark/v1","statusDigest":"$statusDigest"}""",
        )
        Files.move(
            replacement,
            directory,
        )
        val reader = BackupSafetySnapshotReader(jacksonObjectMapper(), properties)
        assertThrows<BackupSafetySnapshotReadException> { reader.read() }
    }

    @Test
    fun `rejects unknown fields duplicate keys and symlink status`() {
        val directory = Files.createTempDirectory("backup-safety-reader")
        val path = directory.resolve("status.json")
        Files.writeString(path, """{"schema":"meet-backend/beta-backup-status/v1","schema":"duplicate"}""")
        val reader = BackupSafetySnapshotReader(
            jacksonObjectMapper(),
            BackupSafetyProperties(environment = "closed-beta", statusPath = path.toString()),
        )
        assertThrows<BackupSafetySnapshotReadException> { reader.read() }
    }
}
