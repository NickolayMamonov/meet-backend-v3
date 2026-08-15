package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties("app.demo-catalog")
data class DemoCatalogProperties(
    val bootstrapEnabled: Boolean = false,
    val allowedMediaHosts: Set<String> = emptySet(),
)
