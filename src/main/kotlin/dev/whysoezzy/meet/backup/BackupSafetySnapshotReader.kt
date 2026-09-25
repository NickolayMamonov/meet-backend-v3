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

class BackupSafetySnapshotReadException(message: String) : RuntimeException(message)

@Component
open class BackupSafetySnapshotReader(
    private val objectMapper: ObjectMapper,
    private val properties: BackupSafetyProperties,
) {
    fun read(): BackupSafetySnapshot {
        val path = Path.of(properties.statusPath)
        val bytes = try {
            require(Files.isRegularFile(path) && !Files.isSymbolicLink(path)) { "status file is unavailable" }
            require(Files.size(path) <= MAX_BYTES) { "status file is too large" }
            Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)
                .use { it.readNBytes(MAX_BYTES.toInt() + 1) }
                .also { require(it.size <= MAX_BYTES) { "status file is too large" } }
        } catch (_: Exception) {
            throw BackupSafetySnapshotReadException("status file is unavailable")
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
            return snapshot
        } catch (_: Exception) {
            throw BackupSafetySnapshotReadException("status schema is invalid")
        }
    }

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
        val TOP_LEVEL_FIELDS = setOf(
            "schema",
            "environment",
            "observedAt",
            "capture",
            "verified",
            "authorityGeneration",
            "authorityDigest",
        )
        val EVIDENCE_FIELDS = setOf("state", "id", "capturedAt")
    }
}
