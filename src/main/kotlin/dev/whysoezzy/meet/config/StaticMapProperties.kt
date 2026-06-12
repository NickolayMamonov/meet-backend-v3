package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties("app.staticmap")
data class StaticMapProperties(
    val baseUrl: String = "https://maps.locationiq.com/v3/staticmap",
    val zoom: Int = 15,
    val width: Int = 640,
    val height: Int = 320,
    val marker: String = "icon:large-red-cutout",
)