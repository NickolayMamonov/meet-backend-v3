package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties("app.geocoder")
data class GeocoderProperties(
    val enabled: Boolean = false,
    val apiKey: String = "",
    val baseUrl: String = "https://eu1.locationiq.com/v1",
    val lang: String = "ru",
)