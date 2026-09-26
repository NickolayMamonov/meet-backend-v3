package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.backup.safety")
data class BackupSafetyProperties(
    val enabled: Boolean = false,
    val enrolled: Boolean = false,
    val environment: String = "",
    val statusPath: String = "/var/lib/meet-production/beta-backup-control/status.json",
    val watermarkPath: String = "",
    val snapshotMaxAgeSeconds: Long = 1_800,
    val verifiedMaxAgeSeconds: Long = 14 * 24 * 60 * 60,
    val controlRootMode: String = "750",
    val controlRootUid: Long = 0,
    val controlRootGid: Long = 10001,
) {
    fun resolvedWatermarkPath(): String =
        watermarkPath.ifBlank {
            java.nio.file.Path.of(statusPath).toAbsolutePath().normalize()
                .resolveSibling("watermark.json")
                .toString()
        }
}
