package dev.whysoezzy.meet.ingestion.timepad

import com.sun.net.httpserver.HttpServer
import dev.whysoezzy.meet.config.TimepadProperties
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.ExtendWith
import org.springframework.boot.test.system.CapturedOutput
import org.springframework.boot.test.system.OutputCaptureExtension
import org.springframework.web.client.RestClient
import java.net.InetSocketAddress
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
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
                "description_short": "Spring and PostgreSQL",
                "starts_at": "2026-09-15T19:00:00+0300",
                "ends_at": "2026-09-15T22:00:00+03:00",
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
            assertEquals(
                OffsetDateTime.parse("2026-09-15T22:00:00+03:00").toInstant().toEpochMilli(),
                event.endsAtEpochMs,
            )
            assertEquals("Test street 1", event.address)
            assertEquals(55.75, event.latitude)
            assertEquals(37.61, event.longitude)
            assertEquals(setOf("ИТ и интернет"), event.topicKeywords)
            assertFalse(event.isOnline)
            assertContains(requestQuery.get(), "ends_at")
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun `maps missing and blank ends to null and isolates invalid ends with sanitized logs`(
        output: CapturedOutput,
    ) {
        val payload =
            """
            {
              "total": 8,
              "values": [
                {
                  "id": 1,
                  "name": "Offset event",
                  "starts_at": "2026-09-15T19:00:00+0300",
                  "ends_at": "2026-09-15T20:00:00+0300"
                },
                {
                  "id": 2,
                  "name": "Missing end",
                  "starts_at": "2026-09-16"
                },
                {
                  "id": 3,
                  "name": "Blank end",
                  "starts_at": "2026-09-16T19:00:00",
                  "ends_at": " "
                },
                {
                  "id": 4,
                  "name": "Secret malformed payload title",
                  "starts_at": "2026-09-17T19:00:00+03:00",
                  "ends_at": "not-a-time"
                },
                {
                  "id": 5,
                  "name": "Secret reversed payload title",
                  "starts_at": "2026-09-18T19:00:00+03:00",
                  "ends_at": "2026-09-18T18:59:59+03:00"
                },
                {
                  "id": 6,
                  "name": "ISO offset event",
                  "starts_at": "2026-09-19T19:00:00+03:00",
                  "ends_at": "2026-09-19T20:00:00+03:00"
                },
                {
                  "id": 7,
                  "name": "Local date-time event",
                  "starts_at": "2026-09-20T19:00:00",
                  "ends_at": "2026-09-20T20:00:00"
                },
                {
                  "id": 8,
                  "name": "Local date event",
                  "starts_at": "2026-09-21",
                  "ends_at": "2026-09-22"
                }
              ]
            }
            """.trimIndent()
        val server = serverReturning(payload)

        try {
            val properties = TimepadProperties().apply {
                baseUrl = "http://127.0.0.1:${server.address.port}"
                maxPages = 1
            }
            val events = TimepadProvider(properties, RestClient.builder()).fetch(null)
            val zone = ZoneId.of(properties.zone)

            assertEquals(listOf("1", "2", "3", "6", "7", "8"), events.map { it.sourceExternalId })
            assertEquals(
                OffsetDateTime.parse("2026-09-15T20:00:00+03:00").toInstant().toEpochMilli(),
                events[0].endsAtEpochMs,
            )
            assertNull(events[1].endsAtEpochMs)
            assertNull(events[2].endsAtEpochMs)
            assertEquals(
                OffsetDateTime.parse("2026-09-19T20:00:00+03:00").toInstant().toEpochMilli(),
                events[3].endsAtEpochMs,
            )
            assertEquals(
                LocalDateTime.parse("2026-09-20T20:00:00").atZone(zone).toInstant().toEpochMilli(),
                events[4].endsAtEpochMs,
            )
            assertEquals(
                LocalDate.parse("2026-09-22").atStartOfDay(zone).toInstant().toEpochMilli(),
                events[5].endsAtEpochMs,
            )

            assertContains(output.all, "source=TIMEPAD externalId=4 reason=malformed_end")
            assertContains(output.all, "source=TIMEPAD externalId=5 reason=end_before_start")
            assertTrue("not-a-time" !in output.all)
            assertTrue("Secret malformed payload title" !in output.all)
            assertTrue("Secret reversed payload title" !in output.all)
        } finally {
            server.stop(0)
        }
    }

    private fun serverReturning(payload: String): HttpServer =
        HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).also { server ->
            server.createContext("/events.json") { exchange ->
                exchange.responseHeaders.add("Content-Type", "application/json")
                exchange.sendResponseHeaders(200, payload.toByteArray().size.toLong())
                exchange.responseBody.use { it.write(payload.toByteArray()) }
            }
            server.start()
        }
}
