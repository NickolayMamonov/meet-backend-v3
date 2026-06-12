package dev.whysoezzy.meet.ingestion

import com.fasterxml.jackson.databind.JsonNode
import dev.whysoezzy.meet.config.GeocoderProperties
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.web.client.RestClient
import java.util.concurrent.ConcurrentHashMap

data class Coordinates(val latitude: Double, val longitude: Double)

@Service
class GeocodingService(
    restClientBuilder: RestClient.Builder,
    private val props: GeocoderProperties,
) {
    private val logger = KotlinLogging.logger {}
    private val cache = ConcurrentHashMap<String, Coordinates>()
    private val client = restClientBuilder.baseUrl(props.baseUrl).build()

    fun geocode(address: String): Coordinates? {
        if (!props.enabled || props.apiKey.isBlank() || address.isBlank()) {
            logger.warn { "Geocode skip: enabled=${props.enabled}, keyLen=${props.apiKey.length}" }
            return null
        }
        cache[address]?.let { return it }
        return request(address)?.also { cache[address] = it }
            ?: run { logger.warn { "Geocode null for '$address'" }; null }
    }

    private fun request(address: String): Coordinates? = try {
        val body: JsonNode? = client.get()
            .uri { b ->
                b.path("/search")
                    .queryParam("key", props.apiKey)
                    .queryParam("q", address)
                    .queryParam("format", "json")
                    .queryParam("limit", 1)
                    .queryParam("accept-language", props.lang)
                    .queryParam("normalizecity", 1)
                    .build()
            }
            .retrieve()
            .body(JsonNode::class.java)

        body?.firstOrNull()?.let { node ->
            val lat = node.path("lat").asText().toDoubleOrNull()
            val lon = node.path("lon").asText().toDoubleOrNull()
            if (lat != null && lon != null) Coordinates(lat, lon) else null
        }
    } catch (e: Exception) {
        logger.warn { "Геокодинг не удался для '$address': ${e.message}" }
        null
    }
}