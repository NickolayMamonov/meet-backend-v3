package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "app.admin")
data class AdminProperties(
    val apiKey: String = "",
)
