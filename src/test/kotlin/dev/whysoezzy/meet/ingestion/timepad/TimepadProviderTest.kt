package dev.whysoezzy.meet.ingestion.timepad

import com.sun.net.httpserver.HttpServer
import dev.whysoezzy.meet.config.TimepadProperties
import dev.whysoezzy.meet.ingestion.FetchContext
import dev.whysoezzy.meet.ingestion.ProviderFetchResult
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.ExtendWith
import org.springframework.boot.test.system.CapturedOutput
import org.springframework.boot.test.system.OutputCaptureExtension
import tools.jackson.databind.ObjectMapper
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@ExtendWith(OutputCaptureExtension::class)
class TimepadProviderTest {
    @Test
    fun `maps representative Timepad payload without changing source semantics`() {
        val payload =
            """
            {
              "total": 1,
              "values": [{
                "id": 4242,
                "name": "Kotlin Backend Meetup",
                "locale": "ru",
                "access_status": "public",
                "registration_data": {"is_registration_open": true},
                "starts_at": "2026-12-15T19:00:00+0300",
                "ends_at": "2026-12-15T22:00:00+03:00",
                "url": "https://timepad.ru/event/4242/",
                "location": {
                  "city": "Москва",
                  "address": "Тестовая улица, 1",
                  "coordinates": ["55.75", "37.61"]
                },
                "categories": [{"id": 452, "name": "ИТ и интернет"}]
              }]
            }
            """.trimIndent()
        val requestQuery = AtomicReference<String>()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/events.json") { exchange ->
            requestQuery.set(exchange.requestURI.rawQuery)
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, payload.toByteArray().size.toLong())
            exchange.responseBody.use { it.write(payload.toByteArray()) }
        }
        server.start()

        try {
            val properties = TimepadProperties().apply {
                baseUrl = "http://127.0.0.1:${server.address.port}"
                assetBaseUrl = "https://assets.example"
            }
            val transport = TimepadHttpClient(properties, ObjectMapper())
            val response = TimepadProvider(properties, transport).fetch(
                FetchContext(Instant.parse("2026-10-21T21:00:00Z"), emptyList()),
            ) as ProviderFetchResult.Complete
            val event = response.accepted.single()

            assertEquals("4242", event.sourceExternalId)
            assertEquals("Kotlin Backend Meetup", event.title)
            assertContains(event.description, "Тема: IT")
            assertContains(event.description, "Тестовая улица, 1")
            assertEquals("https://assets.example/timepad-assets/v1/it.png", event.imageUrl)
            assertEquals(
                OffsetDateTime.parse("2026-12-15T19:00:00+03:00").toInstant().toEpochMilli(),
                event.startsAtEpochMs,
            )
            assertEquals(
                OffsetDateTime.parse("2026-12-15T22:00:00+03:00").toInstant().toEpochMilli(),
                event.endsAtEpochMs,
            )
            assertEquals("Тестовая улица, 1", event.address)
            assertEquals(55.75, event.latitude)
            assertEquals(37.61, event.longitude)
            assertEquals(setOf("ИТ и интернет"), event.topicKeywords)
            assertFalse(event.isOnline)
            assertContains(requestQuery.get(), "ends_at")
            val query = URLDecoder.decode(requestQuery.get(), StandardCharsets.UTF_8)
            assertFalse(query.contains("cities="))
            assertContains(query, "category_ids=452")
            assertContains(query, "category_ids_exclude=379")
            assertContains(query, "limit=100")
            assertContains(query, "skip=0")
            assertContains(query, "sort=+starts_at")
            assertContains(query, "fields=location,categories,ends_at,access_status,registration_data,locale")
            assertContains(query, "starts_at_min=2026-10-22")
            assertContains(query, "starts_at_max=2027-04-20")
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun `maps only exact online venue markers to owned zero-point online events`() {
        val base = validEvent(4242)
        val onlineAddress = base
            .replace(
                "\"city\": \"Москва\", \"address\": \"Тестовая улица, 1\"",
                "\"city\": \"Казань\", \"address\": \" online \", \"coordinates\": [55.75, 37.61]",
            )
        val onlineCity = validEvent(4243)
            .replace(
                "\"city\": \"Москва\", \"address\": \"Тестовая улица, 1\"",
                "\"city\": \"ОНЛАЙН\", \"address\": \"provider prose must not escape\", \"coordinates\": [55.75, 37.61]",
            )
        val onlineFromAddress = listOf(onlineAddress, onlineCity).mapIndexed { index, event ->
            val id = 4242 + index
            val mappedEvent = event.replace("\"id\": 4242", "\"id\": $id")
            val result = fetchDiscovery("""{"total":1,"values":[$mappedEvent]}""")
            assertTrue(result is ProviderFetchResult.Complete, "unexpected result for $event: $result")
            val mapped = result.accepted.single()
            assertEquals("Онлайн", mapped.address)
            assertEquals(0.0, mapped.latitude)
            assertEquals(0.0, mapped.longitude)
            assertTrue(mapped.isOnline)
            assertContains(mapped.description, "Формат: Онлайн. ")
            assertContains(mapped.description, "Место: Онлайн.")
            assertFalse(mapped.description.contains("provider prose"))
            mapped
        }
        assertEquals(listOf("4242", "4243"), onlineFromAddress.map { it.sourceExternalId })

        val nearMatch = base.replace(
            "\"city\": \"Москва\", \"address\": \"Тестовая улица, 1\"",
            "\"city\": \"Тверь\", \"address\": \"Online courses, floor 2\"",
        )
        val rejected = fetchDiscovery("""{"total":1,"values":[$nearMatch]}""") as ProviderFetchResult.Complete
        assertTrue(rejected.accepted.isEmpty())
        val savedRejected = fetchDiscovery(
            """{"total":1,"values":[${nearMatch.replace("\"id\": 4242", "\"id\": 4244")}]}""",
            savedIds = listOf("4244"),
        ) as ProviderFetchResult.Complete
        assertTrue(savedRejected.accepted.isEmpty())
        assertEquals(setOf("4244"), savedRejected.rejectedSavedExternalIds)
    }

    @Test
    fun `online city and address retain the full shared eligibility policy`() {
        val onlineAccepted = listOf(
            withOnlineVenue(validEvent(4300), OnlineMarkerField.CITY),
            withOnlineVenue(validEvent(4301), OnlineMarkerField.ADDRESS),
        )
        val accepted = fetchDiscovery(
            """{"total":2,"values":[${onlineAccepted.joinToString(",")}]}""",
        ) as ProviderFetchResult.Complete
        assertEquals(setOf("4300", "4301"), accepted.accepted.map { it.sourceExternalId }.toSet())
        assertTrue(accepted.rejectedSavedExternalIds.isEmpty())
        accepted.accepted.forEach { assertTrue(it.isOnline) }

        val invalidCases = listOf(
            "non-IT topic" to validEvent(4310).replace("Kotlin backend", "Product manager meetup"),
            "child audience" to validEvent(4311).replace("Kotlin backend", "Kotlin for children"),
            "non-Russian locale" to validEvent(4312).replace("\"locale\": \"ru\"", "\"locale\": \"en\""),
            "private event" to validEvent(4313).replace("\"access_status\": \"public\"", "\"access_status\": \"private\""),
            "closed registration" to validEvent(4314).replace(
                "\"is_registration_open\": true", "\"is_registration_open\": false",
            ),
            "unsafe registration URL" to validEvent(4315).replace(
                "https://timepad.ru/", "https://example.com/",
            ),
            "malformed start" to validEvent(4316).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"not-a-time\"",
            ),
            "malformed end" to validEvent(4317).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\", \"ends_at\": \"not-a-time\"",
            ),
            "end before start" to validEvent(4318).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\", \"ends_at\": \"2026-12-15T18:00:00+03:00\"",
            ),
            "ended event" to validEvent(4319).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"2026-10-20T12:00:00+03:00\", \"ends_at\": \"2026-10-20T13:00:00+03:00\"",
            ),
            "too-early new event" to validEvent(4320).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"2026-10-21T13:00:00+03:00\", \"ends_at\": \"2026-10-21T14:00:00+03:00\"",
            ),
            "too-far-future new event" to validEvent(4321).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"2027-04-20T19:00:00+03:00\"",
            ),
        )
        val onlineInvalid = invalidCases.flatMapIndexed { caseIndex, (reason, event) ->
            listOf(OnlineMarkerField.CITY, OnlineMarkerField.ADDRESS).mapIndexed { index, field ->
                val id = 4400 + caseIndex * 2 + index
                withOnlineVenue(event.replace(Regex("\"id\": \\d+"), "\"id\": $id"), field)
            }
        }
        val savedOngoing = withOnlineVenue(
            validEvent(4500).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"2026-10-20T12:00:00+03:00\", \"ends_at\": \"2026-10-21T14:00:00+03:00\"",
            ),
            OnlineMarkerField.CITY,
        )
        val savedBeyondDiscoveryWindow = withOnlineVenue(
            validEvent(4501).replace(
                "\"starts_at\": \"2026-12-15T19:00:00+03:00\"",
                "\"starts_at\": \"2027-04-20T19:00:00+03:00\"",
            ),
            OnlineMarkerField.ADDRESS,
        )
        val allEvents = onlineInvalid + savedOngoing + savedBeyondDiscoveryWindow
        val payload = """{"total":${allEvents.size},"values":[${allEvents.joinToString(",")}]}"""
        val discovery = fetchDiscovery(payload) as ProviderFetchResult.Complete
        assertTrue(discovery.accepted.isEmpty())

        val newEventWindowCases = setOf("too-early new event", "too-far-future new event")
        val savedIds = invalidCases.flatMapIndexed { caseIndex, (reason, _) ->
            if (reason in newEventWindowCases) {
                emptyList()
            } else {
                listOf((4400 + caseIndex * 2).toString(), (4401 + caseIndex * 2).toString())
            }
        } + listOf("4500", "4501")
        val savedRejectedEvents = invalidCases.flatMapIndexed { caseIndex, (reason, _) ->
            if (reason in newEventWindowCases) emptyList() else onlineInvalid.slice(caseIndex * 2..caseIndex * 2 + 1)
        }
        val savedPayloadEvents = savedRejectedEvents + savedOngoing + savedBeyondDiscoveryWindow
        val savedPayload =
            """{"total":${savedPayloadEvents.size},"values":[${savedPayloadEvents.joinToString(",")}]}"""
        val savedRefresh = fetchResponses(listOf(payload, savedPayload), savedIds) as ProviderFetchResult.Complete
        assertEquals(setOf("4500", "4501"), savedRefresh.accepted.map { it.sourceExternalId }.toSet())
        assertEquals(savedIds.toSet() - setOf("4500", "4501"), savedRefresh.rejectedSavedExternalIds)
    }

    @Test
    fun `adult professional IT scope is enforced independently of discovery filters`() {
        val event = validEvent(4242)
        val rejected = listOf(
            event.replace("Kotlin backend", "Figma UX meetup"),
            event.replace("Kotlin backend", "Product manager meetup"),
            event.replace("Kotlin backend", "Kotlin for children"),
            event.replace("Kotlin backend", "Kotlin для школьников"),
            event.replace("Kotlin backend", "Kotlin для школьника"),
            event.replace("Kotlin backend", "Школьный хакатон по Kotlin"),
            event.replace("Kotlin backend", "Дошкольная разработка на Kotlin"),
            event.replace("Kotlin backend", "Kotlin подростковый клуб"),
            event.replace("Kotlin backend", "Python детям"),
            event.replace("Kotlin backend", "Python for high school students"),
            event.replace("Kotlin backend", "Python for high schoolers"),
            event.replace("Kotlin backend", "Python for your child"),
            event.replace("Kotlin backend", "Children’s Python Camp"),
            event.replace("Kotlin backend", "Children’s Python Meetup"),
            event.replace("Kotlin backend", "Python: children learn to code"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"children learn to code\"}]"),
            event.replace("Kotlin backend", "Python ages 16–18"),
            event.replace("Kotlin backend", "Python ages 8–18"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"children’s Python meetup\"}]"),
            event.replace("Kotlin backend", "Children's Python Camp"),
            event.replace("Kotlin backend", "Python для малышей"),
            event.replace("Kotlin backend", "Python для юных программистов 8–14 лет"),
            event.replace("Kotlin backend", "Python ages 8–14"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"ages 8–14\"}]"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"children’s coding workshop\"}]"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"для малышей\"}]"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"high schoolers\"}]"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"for your child\"}]"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"high school students\"}]"),
            event.replace("Kotlin backend", "Kotlin для учеников средней школы"),
            event.replace("Kotlin backend", "Kotlin для учащихся школы"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"Python детям\"}]"),
            event.replace("\"categories\": []", "\"categories\": [{\"name\":\"учеников средней школы\"}]"),
            event.replace("\"categories\": []", "\"categories\": [{\"id\":379,\"name\":\"Other\"}]"),
        )
        rejected.forEach { value ->
            val result = fetchDiscovery("""{"total":1,"values":[$value]}""") as ProviderFetchResult.Complete
            assertTrue(result.accepted.isEmpty())
            val saved = fetchDiscovery(
                """{"total":1,"values":[$value]}""", listOf("4242"),
            ) as ProviderFetchResult.Complete
            assertTrue(saved.accepted.isEmpty())
            assertEquals(setOf("4242"), saved.rejectedSavedExternalIds)
        }
        // A professional event need not carry an explicit organizer age label.
        val result = fetchDiscovery("""{"total":1,"values":[$event]}""") as ProviderFetchResult.Complete
        assertEquals(1, result.accepted.size)
        for (title in listOf(
            "Kotlin child process management", "Frontend: React children props",
            "Python concurrency for child processes",
            "Python ages 18–25",
        )) {
            val technical = event.replace("Kotlin backend", title)
            for (savedIds in listOf(emptyList(), listOf("4242"))) {
                val accepted = fetchDiscovery(
                    """{"total":1,"values":[$technical]}""", savedIds,
                ) as ProviderFetchResult.Complete
                assertEquals(1, accepted.accepted.size)
                assertTrue(accepted.rejectedSavedExternalIds.isEmpty())
            }
        }
    }

    @Test
    fun `rejects truncated final discovery page and nonempty zero-total envelope`() {
        val event = validEvent(4242)
        val responses = listOf(
            """{"total":2,"values":[$event]}""",
            """{"total":0,"values":[$event]}""",
        )

        responses.forEach { payload ->
            assertEquals(
                ProviderFetchResult.Incomplete("short_page"),
                fetchDiscovery(payload),
            )
        }
    }

    @Test
    fun `global discovery still fails closed above the fixed event budget`() {
        assertEquals(
            ProviderFetchResult.Incomplete("discovery_budget"),
            fetchDiscovery("""{"total":501,"values":[]}"""),
        )
        assertEquals(
            ProviderFetchResult.Incomplete("discovery_budget"),
            fetchDiscovery("""{"total":101,"values":[${(1..101).joinToString(",") { validEvent(it) }}]}"""),
        )
    }

    @Test
    fun `zero and saved snapshots remain complete while malformed and changing snapshots fail closed`() {
        assertEquals(
            ProviderFetchResult.Complete(emptyList(), emptySet(), 0),
            fetchDiscovery("""{"total":0,"values":[]}"""),
        )
        val event = validEvent(4242)
        val saved = fetchDiscovery(
            """{"total":1,"values":[$event]}""", savedIds = listOf("4242"),
        ) as ProviderFetchResult.Complete
        assertEquals(1, saved.accepted.size)
        assertTrue(saved.rejectedSavedExternalIds.isEmpty())

        val firstPage = """{"total":101,"values":[${(1..100).joinToString(",") { validEvent(it) }}]}"""
        assertEquals(
            ProviderFetchResult.Incomplete("changing_total"),
            fetchResponses(listOf(firstPage, """{"total":102,"values":[]}""")),
        )
        val changedSaved = event.replace("Kotlin backend", "Python backend")
        assertEquals(
            ProviderFetchResult.Incomplete("changing_saved_observation"),
            fetchResponses(
                listOf(
                    """{"total":1,"values":[$event]}""",
                    """{"total":1,"values":[$changedSaved]}""",
                ),
                savedIds = listOf("4242"),
            ),
        )
        assertTrue(fetchDiscovery("""{"total":1,"values":"malformed"}""") is ProviderFetchResult.Incomplete)
    }

    private fun fetchDiscovery(payload: String, savedIds: List<String> = emptyList()): ProviderFetchResult {
        return fetchResponses(listOf(payload), savedIds)
    }

    private fun fetchResponses(
        payloads: List<String>,
        savedIds: List<String> = emptyList(),
    ): ProviderFetchResult {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val requestIndex = AtomicInteger()
        server.createContext("/events.json") { exchange ->
            val index = requestIndex.getAndIncrement().coerceAtMost(payloads.lastIndex)
            val body = payloads[index].toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        try {
            val properties = TimepadProperties().apply {
                baseUrl = "http://127.0.0.1:${server.address.port}"
                assetBaseUrl = "https://assets.example"
            }
            return TimepadProvider(properties, TimepadHttpClient(properties, ObjectMapper())).fetch(
                FetchContext(Instant.parse("2026-10-21T10:00:00Z"), savedIds),
            )
        } finally {
            server.stop(0)
        }
    }

    private fun validEvent(id: Int) = """
        {
          "id": $id,
          "name": "Kotlin backend",
          "locale": "ru",
          "access_status": "public",
          "registration_data": {"is_registration_open": true},
          "starts_at": "2026-12-15T19:00:00+03:00",
          "url": "https://timepad.ru/event/$id/",
          "location": {"city": "Москва", "address": "Тестовая улица, 1"},
          "categories": []
        }
    """.trimIndent()

    private fun withOnlineVenue(event: String, field: OnlineMarkerField): String =
        when (field) {
            OnlineMarkerField.CITY -> event.replace(
                "\"city\": \"Москва\"",
                "\"city\": \"Онлайн\"",
            )
            OnlineMarkerField.ADDRESS -> event.replace(
                "\"address\": \"Тестовая улица, 1\"",
                "\"address\": \" online \", \"coordinates\": [55.75, 37.61]",
            )
        }

    private enum class OnlineMarkerField { CITY, ADDRESS }

}
