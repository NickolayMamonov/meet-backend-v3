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
                FetchContext(Instant.parse("2026-10-21T10:00:00Z"), emptyList()),
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
            assertContains(query, "cities=Москва")
            assertContains(query, "category_ids=452")
            assertContains(query, "category_ids_exclude=379")
        } finally {
            server.stop(0)
        }
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

    private fun fetchDiscovery(payload: String, savedIds: List<String> = emptyList()): ProviderFetchResult {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/events.json") { exchange ->
            val body = payload.toByteArray()
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

}
