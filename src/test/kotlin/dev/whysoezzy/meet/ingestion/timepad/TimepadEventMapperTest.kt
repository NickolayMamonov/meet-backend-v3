package dev.whysoezzy.meet.ingestion.timepad

import org.junit.jupiter.api.Test
import tools.jackson.module.kotlin.jacksonObjectMapper
import java.time.Instant
import java.time.ZoneId
import kotlin.test.*

class TimepadEventMapperTest {
    private val json = jacksonObjectMapper()
    private val zone = ZoneId.of("Europe/Moscow")

    @Test
    fun `exact DTO uses preferred description image categories and registration URL`() {
        val event = json.readValue(
            """{"id":42,"name":"Backend","description_short":"Preferred","description_html":"<p>Other</p>",
                "starts_at":"2026-10-18T19:00:00+0300","ends_at":"2026-10-18T20:00:00+03:00",
                "url":"https://club.timepad.ru/event/42/?utm_source=test",
                "poster_image":{"default_url":"https://example.invalid/image.png"},
                "location":{"city":"Москва","address":"Venue 1","coordinates":["55.75","37.61"]},
                "categories":{"452":{"name":"ИТ и интернет"},"other":{"name":""}},"unknown":true}""",
            TimepadEvent::class.java,
        )
        val result = TimepadEventMapper.map(event, zone)
        assertEquals("42", result.sourceExternalId)
        assertEquals("Preferred", result.description)
        assertEquals("https://example.invalid/image.png", result.imageUrl)
        assertEquals(setOf("ИТ и интернет"), result.topicKeywords)
        assertEquals(event.url, result.externalUrl)
        assertEquals(55.75, result.latitude)
        assertEquals(37.61, result.longitude)
        assertFalse(result.isOnline)
        assertEquals(Instant.parse("2026-10-18T16:00:00Z").toEpochMilli(), result.startsAtEpochMs)
        assertEquals(Instant.parse("2026-10-18T17:00:00Z").toEpochMilli(), result.endsAtEpochMs)
        val fallback = TimepadEventMapper.map(event.copy(descriptionShort = " ", categories = json.readTree(
            """[{"name":"Backend"},{"name":"Backend"},{"name":null},{}]""",
        )), zone)
        assertEquals("<p>Other</p>", fallback.description)
        assertEquals(setOf("Backend"), fallback.topicKeywords)
    }

    @Test
    fun `supported timestamp formats represent exact instants`() {
        val values = mapOf(
            "2026-10-18T19:00:00+0300" to "2026-10-18T16:00:00Z",
            "2026-10-18T19:00:00+03:00" to "2026-10-18T16:00:00Z",
            "2026-10-18T16:00:00Z" to "2026-10-18T16:00:00Z",
            "2026-10-18T19:00:00" to "2026-10-18T16:00:00Z",
            "2026-10-18T19:00:00.123" to "2026-10-18T16:00:00.123Z",
            "2026-10-18" to "2026-10-17T21:00:00Z",
        )
        values.forEach { (source, expected) ->
            val result = TimepadEventMapper.map(TimepadEvent(1, startsAt = source, endsAt = source), zone)
            assertEquals(Instant.parse(expected).toEpochMilli(), result.startsAtEpochMs, source)
            assertEquals(result.startsAtEpochMs, result.endsAtEpochMs)
        }
    }

    @Test
    fun `invalid dates never become epoch zero or silently normalize calendar errors`() {
        listOf(null, "", " ").forEach {
            assertEquals(MappingRejection.MISSING_START, assertFailsWith<EventMappingRejection> {
                TimepadEventMapper.map(TimepadEvent(1, startsAt = it), zone)
            }.reason)
        }
        listOf("secret-invalid", "2026-02-30", "2026-02-30T12:00:00+0300", "2026-13-01",
            "+999999999-10-18T19:00:00Z", "+999999999-10-18").forEach {
            assertEquals(MappingRejection.MALFORMED_START, assertFailsWith<EventMappingRejection> {
                TimepadEventMapper.map(TimepadEvent(1, startsAt = it), zone)
            }.reason)
        }
        val event = TimepadEvent(1, startsAt = "2026-10-18")
        assertEquals(MappingRejection.MALFORMED_END, assertFailsWith<EventMappingRejection> {
            TimepadEventMapper.map(event.copy(endsAt = "secret-invalid"), zone)
        }.reason)
        assertEquals(MappingRejection.END_BEFORE_START, assertFailsWith<EventMappingRejection> {
            TimepadEventMapper.map(event.copy(endsAt = "2026-10-17"), zone)
        }.reason)
        assertNull(TimepadEventMapper.map(event.copy(endsAt = " "), zone).endsAtEpochMs)
    }

    @Test
    fun `explicit online address overrides Moscow and irregular optional fields remain tolerated`() {
        for (marker in listOf("Онлайн", " онлайн ", "ONLINE", " Online ")) {
            val location = json.readTree(
                """{"city":"Москва","address":"$marker","coordinates":["55.75","37.61"]}""",
            )
            val mapped = TimepadEventMapper.map(
                TimepadEvent(1, startsAt = "2026-10-18", location = location), zone,
            )
            assertTrue(mapped.isOnline)
            assertEquals("Онлайн", mapped.address)
            assertEquals(0.0, mapped.latitude)
            assertEquals(0.0, mapped.longitude)
        }
        for (shape in listOf("null", "[]", "{}")) {
            val result = TimepadEventMapper.map(
                TimepadEvent(1, startsAt = "2026-10-18", location = json.readTree(shape), posterImage = json.readTree(shape)),
                zone,
            )
            assertEquals(0.0, result.latitude)
            assertEquals("", result.imageUrl)
            assertTrue(result.isOnline)
        }
        val physicalDespiteOnlineCity = TimepadEventMapper.map(TimepadEvent(1, startsAt = "2026-10-18",
            location = json.readTree("""{"city":"Онлайн","address":"Venue 1","coordinates":[55.75,37.61]}""")), zone)
        assertFalse(physicalDespiteOnlineCity.isOnline)
        assertEquals("Venue 1", physicalDespiteOnlineCity.address)
        assertEquals(55.75, physicalDespiteOnlineCity.latitude)
        assertEquals(37.61, physicalDespiteOnlineCity.longitude)
    }
}
