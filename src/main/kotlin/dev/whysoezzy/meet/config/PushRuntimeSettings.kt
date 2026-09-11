package dev.whysoezzy.meet.config

/**
 * The bounded runtime policy shared by push workers and the Firebase adapter.
 *
 * The values are deliberately not configuration properties. Changing them changes
 * admission, retry, and shutdown behavior and therefore requires a reviewed code change.
 */
class PushRuntimeSettings private constructor(
    val providerEnabled: Boolean,
    val discoveryEnabled: Boolean,
    val dispatchEnabled: Boolean,
    val diagnosticEnabled: Boolean,
    val maintenanceEnabled: Boolean,
    internal val projectId: String,
    internal val credentialsFile: String,
) {
    val maintenanceAdmissionEnabled: Boolean
        get() = maintenanceEnabled || discoveryEnabled || dispatchEnabled

    companion object {
        const val DISCOVERY_INTERVAL_SECONDS = 60L
        const val MAINTENANCE_INTERVAL_SECONDS = 60L
        const val IDLE_DISPATCH_DELAY_SECONDS = 1L
        const val PASS_LIMIT = 100
        const val DISPATCH_WORKERS = 4
        const val DIAGNOSTIC_PERMITS = 1
        const val LEASE_MINUTES = 10L
        const val GRACE_MINUTES = 15L
        const val STALENESS_DAYS = 35L
        const val MAX_ATTEMPTS = 5
        const val FCM_CONNECT_TIMEOUT_MS = 5_000
        const val FCM_READ_TIMEOUT_MS = 5_000
        const val FCM_WRITE_TIMEOUT_MS = 5_000

        fun from(properties: PushProperties): PushRuntimeSettings {
            val projectId = properties.projectId
            require(projectId.isNotEmpty() && PROJECT_ID.matches(projectId)) {
                INVALID_CONFIGURATION
            }
            val credentialsFile = properties.credentialsFile
            val providerRequired = properties.discoveryEnabled ||
                properties.dispatchEnabled ||
                properties.diagnosticEnabled
            require(!providerRequired || properties.providerEnabled) { INVALID_CONFIGURATION }
            require(!properties.providerEnabled || credentialsFile.isNotBlank()) { INVALID_CONFIGURATION }

            return PushRuntimeSettings(
                providerEnabled = properties.providerEnabled,
                discoveryEnabled = properties.discoveryEnabled,
                dispatchEnabled = properties.dispatchEnabled,
                diagnosticEnabled = properties.diagnosticEnabled,
                maintenanceEnabled = properties.maintenanceEnabled ||
                    properties.discoveryEnabled ||
                    properties.dispatchEnabled,
                projectId = projectId,
                credentialsFile = credentialsFile,
            )
        }

        private val PROJECT_ID = Regex("^[a-z][a-z0-9-]{4,127}$")
        const val INVALID_CONFIGURATION = "PUSH_CONFIG_INVALID"
    }

    override fun toString(): String = "PushRuntimeSettings(redacted)"
}
