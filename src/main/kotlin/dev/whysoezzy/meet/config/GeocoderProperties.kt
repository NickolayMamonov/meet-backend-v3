package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties("app.geocoder")
data class GeocoderProperties(
    val enabled: Boolean = false,
    val apiKey: String = "",                                 // LocationIQ access token
    val baseUrl: String = "https://us1.locationiq.com/v1",   // Nominatim-совместимый; eu1 — если ближе
    val lang: String = "ru",
)