package dev.whysoezzy.meet.backup

import dev.whysoezzy.meet.config.BackupSafetyProperties
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import tools.jackson.module.kotlin.jacksonObjectMapper
import java.nio.file.Files
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
