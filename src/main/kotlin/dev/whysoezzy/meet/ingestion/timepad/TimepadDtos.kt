package dev.whysoezzy.meet.ingestion.timepad

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.annotation.JsonProperty
import tools.jackson.databind.JsonNode

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadEventsResponse(
    val total: Int?,
    val values: List<TimepadEvent>?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadEvent(
    val id: Long,
    val name: String = "",
    @param:JsonProperty("starts_at") val startsAt: String? = null,
    @param:JsonProperty("ends_at") val endsAt: String? = null,
    val url: String? = null,
    val location: JsonNode? = null,
    val categories: JsonNode? = null,
    val locale: String? = null,
    @param:JsonProperty("access_status") val accessStatus: String? = null,
    @param:JsonProperty("registration_data") val registrationData: JsonNode? = null,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class TimepadImage(
    @param:JsonProperty("default_url") val defaultUrl: String? = null,
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
