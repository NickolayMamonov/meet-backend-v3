package dev.whysoezzy.meet.ingestion.timepad

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.annotation.JsonProperty
import com.fasterxml.jackson.databind.JsonNode

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadEventsResponse(
    val total: Int = 0,
    val values: List<TimepadEvent> = emptyList(),
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadEvent(
    val id: Long,
    val name: String = "",
    @JsonProperty("description_short") val descriptionShort: String? = null,
    @JsonProperty("description_html") val descriptionHtml: String? = null,
    @JsonProperty("starts_at") val startsAt: String? = null,
    val url: String? = null,
    @JsonProperty("poster_image") val posterImage: JsonNode? = null,
    val location: JsonNode? = null,
    val categories: JsonNode? = null,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadImage(
    @JsonProperty("default_url") val defaultUrl: String? = null,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadLocation(
    val country: String? = null,
    val city: String? = null,
    val address: String? = null,
    val coordinates: List<String?>? = null, // Timepad шлёт строками/пустыми — парсим терпимо
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadCategory(
    val id: Int = 0,
    val name: String = "",
)