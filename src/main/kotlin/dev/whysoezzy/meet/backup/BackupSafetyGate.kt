package dev.whysoezzy.meet.backup

import dev.whysoezzy.meet.api.error.BackupSafetyBlockedException
import dev.whysoezzy.meet.config.BackupSafetyProperties
import jakarta.annotation.PostConstruct
import org.springframework.stereotype.Component
import java.time.Clock

@Component
class BackupSafetyGate(
    private val properties: BackupSafetyProperties,
    private val reader: BackupSafetySnapshotReader,
    private val clock: Clock,
) {
    @PostConstruct
    fun validateEnrollmentConfiguration() {
        require(!(properties.enrolled && !properties.enabled)) {
            "backup safety enrollment cannot be enabled while enforcement is disabled"
        }
        if (properties.enabled && properties.enrolled) {
            require(properties.environment.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))) {
                "backup safety environment is invalid"
            }
            require(java.nio.file.Path.of(properties.statusPath).isAbsolute) {
                "backup safety status path must be absolute"
            }
        }
    }

    fun requireAdmitted(operation: String = "operation") {
        if (!properties.enabled) return
        if (!properties.enrolled) throw BackupSafetyBlockedException("backup safety enrollment is unavailable")
        val snapshot = try {
            reader.read()
        } catch (_: BackupSafetySnapshotReadException) {
            throw BackupSafetyBlockedException("backup safety snapshot is unavailable")
        }
        val now = clock.instant().epochSecond
        requireFreshObservation(snapshot.observedAtEpochSeconds, now)
        requireVerified(snapshot, now)
    }

    private fun requireFreshObservation(observedAt: Long, now: Long) {
        if (observedAt > now || now - observedAt > properties.snapshotMaxAgeSeconds) {
            throw BackupSafetyBlockedException("backup safety observation is stale")
        }
    }

    private fun requireVerified(snapshot: BackupSafetySnapshot, now: Long) {
        val verified = snapshot.verified
        if (verified.state != BackupEvidenceState.VALID) {
            throw BackupSafetyBlockedException("backup verification is unavailable")
        }
        val capturedAt = verified.capturedAtEpochSeconds
            ?: throw BackupSafetyBlockedException("backup verification is unavailable")
        if (capturedAt > now || now - capturedAt >= properties.verifiedMaxAgeSeconds) {
            throw BackupSafetyBlockedException("backup verification is stale")
        }
    }

    companion object {
        fun disabled(): BackupSafetyGate = BackupSafetyGate(
            BackupSafetyProperties(),
            object : BackupSafetySnapshotReader(
                tools.jackson.module.kotlin.jacksonObjectMapper(),
                BackupSafetyProperties(),
            ) {},
            Clock.systemUTC(),
        )
    }
}
