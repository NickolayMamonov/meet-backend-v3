package dev.whysoezzy.meet.ingestion.timepad

import org.junit.jupiter.api.Test
import tools.jackson.module.kotlin.jacksonObjectMapper
import java.time.Instant
import kotlin.test.*

class TimepadOfflinePreviewTest {
    private val json = jacksonObjectMapper()
    private val asOf = Instant.parse("2026-10-17T00:00:00Z")
    private val preview = TimepadOfflinePreview()
    private fun event(
        location: String = """{"city":"Москва","address":"Venue 1","coordinates":["55.75","37.61"]}""",
    ) = TimepadEvent(1, "Backend meetup", startsAt = "2026-10-18T19:00:00+0300",
        url = "https://club.timepad.ru/event/1/", location = json.readTree(location))
    private fun result(event: TimepadEvent, format: ReviewedFormat = ReviewedFormat.MOSCOW_PHYSICAL) =
        preview.evaluate(listOf(event), listOf(ReviewedEvent(event.id, format)), asOf, "input", "review").results.single()

    @Test
    fun `Moscow aliases accept reviewed physical address with or without coordinates`() {
        for (city in listOf("Москва", " Moscow ", "МОСКВА", "moscow")) {
            for (coordinates in listOf("", ""","coordinates":[]""", ""","coordinates":[0,0]""")) {
                val result = result(event("""{"city":"$city","address":"Venue 1"$coordinates}"""))
                assertEquals(PreviewStatus.CANDIDATE, result.status)
                assertEquals(listOf(PreviewWarning.COORDINATES_MISSING_MAP_UNAVAILABLE), result.warnings)
                assertEquals(0.0, result.normalized!!.latitude)
                assertEquals(0.0, result.normalized.longitude)
                assertEquals(listOf("Backend"), result.topics)
            }
        }
        assertTrue(result(event()).warnings.isEmpty())
    }

    @Test
    fun `explicit online markers require consistent human review and no physical coordinates`() {
        for (location in listOf(
            """{"city":"Москва","address":"Онлайн"}""",
            """{"city":"Online","coordinates":[]}""",
            """{"address":" онлайн ","coordinates":[0,0]}""",
        )) {
            val result = result(event(location), ReviewedFormat.ONLINE)
            assertEquals(PreviewStatus.CANDIDATE, result.status)
            assertTrue(result.normalized!!.isOnline)
            assertTrue(result.warnings.isEmpty())
        }
        assertEquals(PreviewRejection.FORMAT_REVIEW_MISMATCH, result(event(), ReviewedFormat.ONLINE).code)
        assertEquals(PreviewRejection.FORMAT_REVIEW_MISMATCH,
            result(event("""{"city":"Москва","address":"Онлайн"}""")).code)
    }

    @Test
    fun `ambiguous location is not manufactured from mapper defaults`() {
        val cases = mapOf(
            "null" to PreviewRejection.FORMAT_AMBIGUOUS,
            "[]" to PreviewRejection.FORMAT_AMBIGUOUS,
            "{}" to PreviewRejection.FORMAT_AMBIGUOUS,
            """{"city":42,"address":"Venue"}""" to PreviewRejection.FORMAT_AMBIGUOUS,
            """{"city":"Online","address":"Venue"}""" to PreviewRejection.FORMAT_AMBIGUOUS,
            """{"city":"Kazan","address":"Venue"}""" to PreviewRejection.CITY_OUT_OF_SCOPE,
            """{"city":"Москва"}""" to PreviewRejection.ADDRESS_MISSING,
            """{"city":"Москва","address":" Moscow "}""" to PreviewRejection.ADDRESS_AMBIGUOUS,
        )
        cases.forEach { (location, code) -> assertEquals(code, result(event(location)).code, location) }
    }

    @Test
    fun `malformed coordinates reject rather than silently becoming zero`() {
        val malformed = listOf("null", "{}", """["55.75"]""", "[1,2,3]", """["NaN",0]""",
            """["Infinity",0]""", """["bad",0]""", "[91,0]", "[0,181]", "[true,0]", "[null,0]")
        for (coords in malformed) {
            for ((city, address, format) in listOf(
                Triple("Москва", "Venue", ReviewedFormat.MOSCOW_PHYSICAL),
                Triple("Москва", "Онлайн", ReviewedFormat.ONLINE),
            )) {
                val location = """{"city":"$city","address":"$address","coordinates":$coords}"""
                assertEquals(PreviewRejection.COORDINATES_INVALID, result(event(location), format).code, coords)
            }
        }
        assertEquals(PreviewRejection.ONLINE_COORDINATE_CONFLICT,
            result(event("""{"address":"Online","coordinates":[55,37]}"""), ReviewedFormat.ONLINE).code)
        assertEquals(PreviewStatus.CANDIDATE, result(event("""{"city":"Moscow","address":"Venue","coordinates":[-90,180]}""")).status)
    }

    @Test
    fun `only exact Timepad HTTPS registration identity is accepted without resolving hosts`() {
        for (url in listOf("https://timepad.ru/event/1", "https://club.timepad.ru:443/event/1/?x=1#registration")) {
            assertEquals(PreviewStatus.CANDIDATE, result(event().copy(url = url)).status)
        }
        for (url in listOf(null, "", "http://timepad.ru/event/1", "https://timepad.ru.evil.test/event/1",
            "https://eviltimepad.ru/event/1", "https://evil.test@timepad.ru/event/1",
            "https://timepad.ru:/event/1", "https://timepad.ru:abc/event/1",
            "https://timepad.ru:+443/event/1", "https://timepad.ru:0443/event/1",
            "https://timepad.ru:443:/event/1",
            "https://timepad.ru:444/event/1", "https://timepad.ru/event/%31", "https://timepad.ru/event/01",
            "https://timepad.ru/event/1/extra", "https://timepad.ru/event/1/../1", "//timepad.ru/event/1")) {
            assertEquals(PreviewRejection.INVALID_SOURCE_URL, result(event().copy(url = url)).code, url)
        }
        assertEquals(PreviewRejection.SOURCE_URL_ID_MISMATCH, result(event().copy(url = "https://timepad.ru/event/2")).code)
    }

    @Test
    fun `eligibility boundary order is deterministic and never substitutes for review`() {
        assertEquals(PreviewRejection.EMPTY_TITLE, result(event().copy(name = " ")).code)
        assertEquals(PreviewRejection.MISSING_START, result(event().copy(startsAt = null, name = "")).code)
        assertEquals(PreviewRejection.MALFORMED_START, result(event().copy(startsAt = "bad")).code)
        assertEquals(PreviewRejection.MALFORMED_END, result(event().copy(endsAt = "bad")).code)
        assertEquals(PreviewRejection.END_BEFORE_START, result(event().copy(endsAt = "2026-10-17")).code)
        assertEquals(PreviewRejection.NOT_FUTURE, result(event().copy(startsAt = asOf.toString())).code)
        assertEquals(PreviewStatus.CANDIDATE, result(event().copy(startsAt = asOf.plusMillis(1).toString())).status)
        val end = asOf.plusSeconds(30L * 86400)
        assertEquals(PreviewStatus.CANDIDATE, result(event().copy(startsAt = end.toString())).status)
        assertEquals(PreviewRejection.OUTSIDE_30_DAY_WINDOW, result(event().copy(startsAt = end.plusMillis(1).toString())).code)
        assertEquals(PreviewRejection.NO_MATCHING_TOPIC, result(event().copy(name = "Poetry")).code)
        assertEquals(listOf("IT"), result(event().copy(name = "Conference",
            categories = json.readTree("""[{"name":"ИТ и интернет"}]"""))).topics)
    }

    @Test
    fun `report reconciles counts and stable order including zero candidates`() {
        val events = listOf(event().copy(id = 3), event().copy(id = 2, startsAt = null), event())
        val reviewed = listOf(ReviewedEvent(1, ReviewedFormat.MOSCOW_PHYSICAL), ReviewedEvent(2, ReviewedFormat.ONLINE))
        val report = preview.evaluate(events, reviewed, asOf, "input", "review")
        assertEquals(listOf(1L, 2L, 3L), report.results.map { it.id })
        assertEquals(PreviewCounts(3, 2, 1, 2, 1), report.counts)
        assertEquals(PreviewRejection.NOT_REVIEWED, report.results.last().code)
        assertEquals(PreviewIdentity(externalId = "1"), report.results.first().identity)
        assertEquals("OFFLINE_CANDIDATES_ONLY", report.mode)
        assertFalse(report.databaseCompared)
        assertEquals(report, preview.evaluate(events.reversed(), reviewed.reversed(), asOf, "input", "review"))
        assertEquals(0, preview.evaluate(listOf(event().copy(startsAt = null)), reviewed.take(1),
            asOf, "input", "review").counts.candidates)
    }
}
