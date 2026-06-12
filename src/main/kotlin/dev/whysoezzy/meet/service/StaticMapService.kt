package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.StaticMapProperties
import org.springframework.stereotype.Service
import org.springframework.cache.annotation.Cacheable
import org.springframework.web.client.RestClient

@Service
class StaticMapService(
    restClientBuilder: RestClient.Builder,
    private val props: StaticMapProperties,
    private val geocoderProps: GeocoderProperties,   // общий ключ LocationIQ
) {
    private val client = restClientBuilder.build()

    @Cacheable("staticMaps", key = "T(java.lang.String).format('%.5f,%.5f', #lat, #lon)")
    fun render(lat: Double, lon: Double): ByteArray? {
        if (geocoderProps.apiKey.isBlank()) return null
        val center = "$lat,$lon"
        val url = buildString {
            append(props.baseUrl)
            append("?key=").append(geocoderProps.apiKey)
            append("&center=").append(center)
            append("&zoom=").append(props.zoom)
            append("&size=").append(props.width).append("x").append(props.height)
            append("&format=png")
            append("&markers=").append(props.marker).append("|").append(center)
        }
        return client.get().uri(url).retrieve().body(ByteArray::class.java)
    }
}