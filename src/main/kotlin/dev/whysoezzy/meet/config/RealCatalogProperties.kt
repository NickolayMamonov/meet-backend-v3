package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties("app.real-catalog")
data class RealCatalogProperties(
    val enabled: Boolean = false,
    val targetEnvironment: String = "",
    val approvedMediaHosts: Set<String> = emptySet(),
    val attestationSecret: String = "",
    val maxRequestBytes: Int = 16 * 1024,
)
