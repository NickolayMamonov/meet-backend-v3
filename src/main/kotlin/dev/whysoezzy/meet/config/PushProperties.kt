package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.push")
class PushProperties(
    val providerEnabled: Boolean = false,
    val discoveryEnabled: Boolean = false,
    val dispatchEnabled: Boolean = false,
    val diagnosticEnabled: Boolean = false,
    val maintenanceEnabled: Boolean = false,
    val projectId: String = "meeting-1d258",
    val credentialsFile: String = "",
) {
    override fun toString(): String = "PushProperties(redacted)"
}
