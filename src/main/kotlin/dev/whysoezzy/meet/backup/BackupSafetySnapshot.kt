package dev.whysoezzy.meet.backup

import java.time.Instant

enum class BackupEvidenceState {
    VALID,
    MISSING,
    INVALID,
}

data class BackupEvidence(
    val state: BackupEvidenceState,
    val id: String?,
    val capturedAtEpochSeconds: Long?,
)

data class BackupSafetySnapshot(
    val schema: String,
    val environment: String,
    val observedAtEpochSeconds: Long,
    val capture: BackupEvidence,
    val verified: BackupEvidence,
    val authorityGeneration: Long,
    val authorityDigest: String,
) {
    fun observedAt(): Instant = Instant.ofEpochSecond(observedAtEpochSeconds)

    companion object {
        const val SCHEMA = "meet-backend/beta-backup-status/v1"
        const val ID_PATTERN = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
        const val DIGEST_PATTERN = "^[0-9a-f]{64}$"
    }
}
