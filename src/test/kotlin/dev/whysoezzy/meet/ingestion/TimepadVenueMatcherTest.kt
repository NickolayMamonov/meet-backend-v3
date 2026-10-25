package dev.whysoezzy.meet.ingestion

import org.junit.jupiter.api.Test
import tools.jackson.databind.ObjectMapper
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertNotNull

class TimepadVenueMatcherTest {
    private val mapper = ObjectMapper()
    private val expected = TimepadVenueMatcher.parseInput("Новодмитровская, 1, стр 1")!!

    @Test
    fun `grammar bounds NFC and unsupported punctuation never broaden venue equality`() {
        assertNotNull(TimepadVenueMatcher.parseInput(" ".repeat(1700) + "Синтетическая 1"))
        assertEquals(
            TimepadVenueMatcher.parseInput("Ёлочная 1"),
            TimepadVenueMatcher.parseInput("Е\u0308лочная 1"),
        )
        kotlin.test.assertNotEquals(
            TimepadVenueMatcher.parseInput("Ёлочная 1"),
            TimepadVenueMatcher.parseInput("Елочная 1"),
        )
        for (input in listOf(
            "Новодмитровская 01", "Новодмитровская 0", "Новодмитровская 1000000",
            "Новодмитровская 1, стр 01", "Новодмитровская, , 1",
            "улица Новодмитровская улица 1", "Новодмитровская улица Большая 1",
            "Новодмитровская\u202e 1", "Новодмитровская\u200b 1",
        )) assertNull(TimepadVenueMatcher.parseInput(input), input)
        val road = "Новодмитровская улица"
        assertNotNull(TimepadVenueMatcher.parseCandidate(candidate(road = road.padEnd(128))).venue)
        assertNull(TimepadVenueMatcher.parseCandidate(candidate(road = road.padEnd(129))).venue)
        assertNull(TimepadVenueMatcher.parseCandidate(candidate(house = "1 стр 1".padEnd(129))).venue)
        assertNull(TimepadVenueMatcher.select(expected, listOf(
            TimepadVenueMatcher.parseCandidate(candidate(road = "Novodmitrovskaya улица")),
        )))
    }

    @Test
    fun `accepted street and structure spellings normalize into same tuple`() {
        listOf(
            "Россия, г. Москва, Новодмитровская Улица, дом 1, строение 1",
            "город Москва, улица Новодмитровская, 1 с1",
            "Новодмитровская ул., 1с1",
            "  НОВОДМИТРОВСКАЯ 1 СТР 1  ",
            "Новодмитровская, 1с 1",
        ).forEach { assertEquals(expected, TimepadVenueMatcher.parseInput(it), it) }
        assertEquals(
            expected,
            TimepadVenueMatcher.parseCandidate(candidate(road = "улица Новодмитровская", house = "1 с 1")).venue,
        )
        assertEquals(
            expected,
            TimepadVenueMatcher.parseCandidate(candidate(road = "Новодмитровская улица")).venue,
        )
    }

    @Test
    fun `unsupported input and mismatched structures fail closed`() {
        listOf(
            "Новодмитровская, 1, корпус 1", "Новодмитровская, 1c1",
            "Новодмитровская, 1/1", "Новодмитровская, 1а", "Новодмитровская 2, 1",
            "переулок Новодмитровский, 1", "Новодмитровская, 1, стр 1 офис 2",
            "Новодмитровская\u0000, 1", "x".repeat(2049), "Новодмитровская, 1, стр 1, офис 2",
            "Новодмитровская, 1, стр 1, стр 2", "Новодмитровская, 1, к 1",
            "НоводмитровскаяУлица, 1", "foo, Новодмитровская, 1",
        ).forEach { assertNull(TimepadVenueMatcher.parseInput(it), it) }
        assertNull(
            TimepadVenueMatcher.select(
                expected,
                listOf(TimepadVenueMatcher.parseCandidate(candidate(road = "Новодмитровская", house = "1"))),
            ),
        )
        assertNull(
            TimepadVenueMatcher.select(
                expected,
                listOf(TimepadVenueMatcher.parseCandidate(candidate(road = "Новодмитровская", house = "1 стр 2"))),
            ),
        )
    }

    @Test
    fun `accepts only eligible identical points for multiple results`() {
        val first = TimepadVenueMatcher.parseCandidate(candidate(lat = "55.0", lon = "37.0"))
        val same = TimepadVenueMatcher.parseCandidate(candidate(lat = "55.000", lon = "37.000"))
        val different = TimepadVenueMatcher.parseCandidate(candidate(lat = "55.01", lon = "37.0"))
        assertEquals(Coordinates(55.0, 37.0), TimepadVenueMatcher.select(expected, listOf(first)))
        assertEquals(Coordinates(55.0, 37.0), TimepadVenueMatcher.select(expected, listOf(first, same)))
        assertEquals(Coordinates(55.0, 37.0), TimepadVenueMatcher.select(expected, listOf(same, first)))
        assertNull(TimepadVenueMatcher.select(expected, listOf(first, different)))
        assertNull(TimepadVenueMatcher.select(expected, listOf(first, first, first)))
        assertNull(TimepadVenueMatcher.select(expected, emptyList()))
    }

    @Test
    fun `provider candidate eligibility requires Moscow Russia exact point building venue and valid coordinates`() {
        val good = TimepadVenueMatcher.parseCandidate(candidate()).also { assertNotNull(it.venue) }
        assertEquals(Coordinates(55.0, 37.0), TimepadVenueMatcher.select(expected, listOf(good)))

        listOf(
            candidate(country = "us"),
            candidate(city = "Химки"),
            candidate(code = "fallback"),
            candidate(type = "interpolated"),
            candidate(level = "street"),
            candidate(lat = "NaN"),
            candidate(lon = "Infinity"),
            candidate(lat = "91"),
            candidate(lon = "181"),
            candidate(lat = "0", lon = "0"),
            candidate(road = "Новодмитровская"),
            candidate(road = "Новодмитровская переулок"),
            candidate(road = "Новодмитровская улица проезд"),
            candidate(house = "1"),
            candidate(house = "1 стр 2"),
        ).forEach { invalid ->
            assertNull(
                TimepadVenueMatcher.select(expected, listOf(TimepadVenueMatcher.parseCandidate(invalid))),
            )
        }
    }

    @Test
    fun `two results require both eligible candidates to identify same exact point in either order`() {
        val a = TimepadVenueMatcher.parseCandidate(candidate(lat = "55.0", lon = "37.0"))
        val b = TimepadVenueMatcher.parseCandidate(candidate(lat = "55.000", lon = "37.000"))
        assertEquals(Coordinates(55.0, 37.0), TimepadVenueMatcher.select(expected, listOf(a, b)))
        assertEquals(Coordinates(55.0, 37.0), TimepadVenueMatcher.select(expected, listOf(b, a)))

        val near = TimepadVenueMatcher.parseCandidate(candidate(lat = "55.00000001", lon = "37.0"))
        assertNull(TimepadVenueMatcher.select(expected, listOf(a, near)))
        val doubleRoundedNear = TimepadVenueMatcher.parseCandidate(candidate(lat = "55.00000000000000001", lon = "37.0"))
        assertNull(TimepadVenueMatcher.select(expected, listOf(a, doubleRoundedNear)))
        val outOfRangeDecimal = TimepadVenueMatcher.parseCandidate(candidate(lat = "90.00000000000000001", lon = "37.0"))
        assertNull(TimepadVenueMatcher.select(expected, listOf(outOfRangeDecimal)))
        assertNull(TimepadVenueMatcher.select(expected, listOf(a, TimepadVenueMatcher.parseCandidate(candidate(country = "us")))))
        assertNull(TimepadVenueMatcher.select(expected, listOf(a, TimepadVenueMatcher.parseCandidate(candidate(house = "2 стр 1")))))
    }

    private fun candidate(
        road: String = "Новодмитровская улица",
        house: String = "1 стр 1",
        lat: String = "55.0",
        lon: String = "37.0",
        country: String = "ru",
        city: String = "Москва",
        code: String = "exact",
        type: String = "point",
        level: String = "building",
    ) = mapper.readTree(
        """{"lat":"$lat","lon":"$lon","address":{"road":"$road","house_number":"$house","country_code":"$country","city":"$city"},"matchquality":{"matchcode":"$code","matchtype":"$type","matchlevel":"$level"}}""",
    )
}
