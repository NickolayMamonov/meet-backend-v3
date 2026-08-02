package dev.whysoezzy.meet.ingestion.timepad

import com.sun.net.httpserver.HttpServer
import dev.whysoezzy.meet.config.TimepadProperties
import org.junit.jupiter.api.Test
import org.springframework.web.client.RestClient
import java.net.InetSocketAddress
import java.time.OffsetDateTime
import kotlin.test.assertEquals
import kotlin.test.assertFalse

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
                "description_short": "Spring and PostgreSQL",
                "starts_at": "2026-09-15T19:00:00+0300",
                "url": "https://timepad.test/event/4242",
                "poster_image": {"default_url": "https://img.test/4242.png"},
                "location": {
                  "city": "Moscow",
                  "address": "Test street 1",
                  "coordinates": ["55.75", "37.61"]
                },
                "categories": [{"id": 452, "name": "ИТ и интернет"}]
              }]
            }
            """.trimIndent()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/events.json") { exchange ->
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, payload.toByteArray().size.toLong())
            exchange.responseBody.use { it.write(payload.toByteArray()) }
        }
        server.start()

        try {
            val properties = TimepadProperties().apply {
                baseUrl = "http://127.0.0.1:${server.address.port}"
                maxPages = 1
            }
            val event = TimepadProvider(properties, RestClient.builder()).fetch(null).single()

            assertEquals("4242", event.sourceExternalId)
            assertEquals("Kotlin Backend Meetup", event.title)
            assertEquals("Spring and PostgreSQL", event.description)
            assertEquals("https://img.test/4242.png", event.imageUrl)
            assertEquals(
                OffsetDateTime.parse("2026-09-15T19:00:00+03:00").toInstant().toEpochMilli(),
                event.startsAtEpochMs,
            )
            assertEquals("Test street 1", event.address)
            assertEquals(55.75, event.latitude)
            assertEquals(37.61, event.longitude)
            assertEquals(setOf("ИТ и интернет"), event.topicKeywords)
            assertFalse(event.isOnline)
        } finally {
            server.stop(0)
        }
    }
}
