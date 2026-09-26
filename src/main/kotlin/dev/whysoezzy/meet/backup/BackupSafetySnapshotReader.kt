package dev.whysoezzy.meet.backup

import dev.whysoezzy.meet.config.BackupSafetyProperties
import org.springframework.stereotype.Component
import tools.jackson.core.StreamReadFeature
import tools.jackson.databind.DeserializationFeature
import tools.jackson.databind.JsonNode
import tools.jackson.databind.ObjectMapper
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission

class BackupSafetySnapshotReadException(message: String) : RuntimeException(message)

@Component
open class BackupSafetySnapshotReader(
    private val objectMapper: ObjectMapper,
    private val properties: BackupSafetyProperties,
) {
    fun validateEnrollmentMount() {
        val root = controlRoot()
        require(Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS))
        require(!Files.isSymbolicLink(root))
        val mode = runCatching {
            Files.getPosixFilePermissions(root).toMode()
        }.getOrNull()
        if (mode != null) {
            require(mode == properties.controlRootMode.toInt(8))
        }
        val status = Path.of(properties.statusPath)
        val watermark = Path.of(properties.resolvedWatermarkPath())
        require(Files.isRegularFile(status, LinkOption.NOFOLLOW_LINKS))
        require(Files.isRegularFile(watermark, LinkOption.NOFOLLOW_LINKS))
        if (mode != null) {
            require(readMode(status) == CONTROL_FILE_MODE)
            require(readMode(watermark) == CONTROL_FILE_MODE)
            require(readUnixOwner(root, "uid") == properties.controlRootUid)
            require(readUnixOwner(root, "gid") == properties.controlRootGid)
            require(readUnixOwner(status, "uid") == properties.controlRootUid)
            require(readUnixOwner(status, "gid") == properties.controlRootGid)
            require(readUnixOwner(watermark, "uid") == properties.controlRootUid)
            require(readUnixOwner(watermark, "gid") == properties.controlRootGid)
        }
    }

    fun read(): BackupSafetySnapshot {
        val path = Path.of(properties.statusPath)
        val bytes = try {
            validateRootForRead()
            require(Files.isRegularFile(path) && !Files.isSymbolicLink(path)) { "status file is unavailable" }
            require(Files.size(path) <= MAX_BYTES) { "status file is too large" }
            Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)
                .use { it.readNBytes(MAX_BYTES.toInt() + 1) }
                .also { require(it.size <= MAX_BYTES) { "status file is too large" } }
        } catch (_: Exception) {
            throw BackupSafetySnapshotReadException("status file is unavailable")
        }
        val watermarkBytes = try {
            val watermarkPath = Path.of(properties.resolvedWatermarkPath())
            require(Files.isRegularFile(watermarkPath) && !Files.isSymbolicLink(watermarkPath))
            require(Files.size(watermarkPath) <= MAX_BYTES)
            Files.readAllBytes(watermarkPath)
        } catch (_: Exception) {
            throw BackupSafetySnapshotReadException("watermark is unavailable")
        }
        try {
            val reader = objectMapper.reader(
                DeserializationFeature.FAIL_ON_TRAILING_TOKENS,
            ).with(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
            val root = reader.readTree(bytes)
            require(root.isObject) { "status must be an object" }
            require(root.propertyNames().asSequence().toSet() == TOP_LEVEL_FIELDS) { "status fields are invalid" }
            val snapshot = BackupSafetySnapshot(
                schema = requiredText(root, "schema"),
                environment = requiredText(root, "environment"),
                observedAtEpochSeconds = requiredLong(root, "observedAt"),
                capture = evidence(root, "capture"),
                verified = evidence(root, "verified"),
                authorityGeneration = requiredLong(root, "authorityGeneration"),
                authorityDigest = requiredText(root, "authorityDigest"),
            )
            require(snapshot.schema == BackupSafetySnapshot.SCHEMA)
            require(snapshot.environment == properties.environment && snapshot.environment.isNotBlank())
            require(snapshot.observedAtEpochSeconds >= 0)
            require(snapshot.authorityGeneration >= 0)
            require(snapshot.authorityDigest.matches(Regex(BackupSafetySnapshot.DIGEST_PATTERN)))
            validateEvidence(snapshot.capture, snapshot.observedAtEpochSeconds)
            validateEvidence(snapshot.verified, snapshot.observedAtEpochSeconds)
            validateWatermark(watermarkBytes, snapshot, bytes)
            return snapshot
        } catch (_: Exception) {
            throw BackupSafetySnapshotReadException("status schema is invalid")
        }
    }

    private fun validateRootForRead() {
        val root = controlRoot()
        require(Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS))
        require(!Files.isSymbolicLink(root))
    }

    private fun readMode(path: Path): Int =
        Files.getPosixFilePermissions(path).toMode()

    private fun readUnixOwner(path: Path, field: String): Long =
        (Files.readAttributes(path, "unix:$field", LinkOption.NOFOLLOW_LINKS)[field] as Number).toLong()

    private fun controlRoot(): Path = Path.of(properties.statusPath).toAbsolutePath().normalize().parent
        ?: throw IllegalArgumentException("status path has no parent")

    private fun validateWatermark(bytes: ByteArray, snapshot: BackupSafetySnapshot, statusBytes: ByteArray) {
        val root = objectMapper.reader(
            DeserializationFeature.FAIL_ON_TRAILING_TOKENS,
        ).with(StreamReadFeature.STRICT_DUPLICATE_DETECTION).readTree(bytes)
        require(root.isObject)
        require(root.propertyNames().asSequence().toSet() == WATERMARK_FIELDS)
        require(root.path("schema").textValue() == WATERMARK_SCHEMA)
        require(root.path("authorityGeneration").isIntegralNumber)
        require(root.path("observedAt").isIntegralNumber)
        require(root.path("statusDigest").textValue()?.matches(Regex(BackupSafetySnapshot.DIGEST_PATTERN)) == true)
        require(root.path("authorityGeneration").longValue() == snapshot.authorityGeneration)
        require(root.path("observedAt").longValue() == snapshot.observedAtEpochSeconds)
        require(root.path("statusDigest").textValue() == sha256(statusBytes))
    }

    private fun sha256(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private fun evidence(root: JsonNode, name: String): BackupEvidence {
        val node = root.get(name)
        require(node != null && node.isObject)
        require(node.propertyNames().asSequence().toSet() == EVIDENCE_FIELDS)
        val state = requiredText(node, "state")
        val idNode = node.get("id")
        val timestampNode = node.get("capturedAt")
        require(idNode == null || idNode.isNull || idNode.isTextual)
        require(timestampNode == null || timestampNode.isNull || timestampNode.isIntegralNumber)
        return BackupEvidence(
            state = BackupEvidenceState.valueOf(state),
            id = idNode?.takeUnless { it.isNull }?.textValue(),
            capturedAtEpochSeconds = timestampNode?.takeUnless { it.isNull }?.longValue(),
        )
    }

    private fun validateEvidence(evidence: BackupEvidence, observedAt: Long) {
        when (evidence.state) {
            BackupEvidenceState.VALID -> {
                require(evidence.id?.matches(Regex(BackupSafetySnapshot.ID_PATTERN)) == true)
                require(evidence.capturedAtEpochSeconds != null && evidence.capturedAtEpochSeconds >= 0)
                require(evidence.capturedAtEpochSeconds <= observedAt)
            }
            BackupEvidenceState.MISSING, BackupEvidenceState.INVALID -> {
                require(evidence.id == null && evidence.capturedAtEpochSeconds == null)
            }
        }
    }

    private fun requiredText(root: JsonNode, name: String): String {
        val node = root.get(name)
        require(node != null && node.isTextual && node.textValue().isNotBlank())
        return node.textValue()
    }

    private fun requiredLong(root: JsonNode, name: String): Long {
        val node = root.get(name)
        require(node != null && node.isIntegralNumber)
        return node.longValue()
    }

    private companion object {
        const val MAX_BYTES = 64 * 1024L
        const val CONTROL_FILE_MODE = 640
        const val WATERMARK_SCHEMA = "meet-backend/beta-backup-watermark/v1"
        val TOP_LEVEL_FIELDS = setOf(
            "schema",
            "environment",
            "observedAt",
            "capture",
            "verified",
            "authorityGeneration",
            "authorityDigest",
        )
        val WATERMARK_FIELDS = setOf("authorityGeneration", "observedAt", "schema", "statusDigest")
        val EVIDENCE_FIELDS = setOf("state", "id", "capturedAt")
    }
}

private fun Set<PosixFilePermission>.toMode(): Int {
    fun has(permission: PosixFilePermission) = if (contains(permission)) 1 else 0
    return has(PosixFilePermission.OWNER_READ) * 400 +
        has(PosixFilePermission.OWNER_WRITE) * 200 +
        has(PosixFilePermission.OWNER_EXECUTE) * 100 +
        has(PosixFilePermission.GROUP_READ) * 40 +
        has(PosixFilePermission.GROUP_WRITE) * 20 +
        has(PosixFilePermission.GROUP_EXECUTE) * 10 +
        has(PosixFilePermission.OTHERS_READ) * 4 +
        has(PosixFilePermission.OTHERS_WRITE) * 2 +
        has(PosixFilePermission.OTHERS_EXECUTE)
}
