package dev.whysoezzy.meet.ingestion

import com.sun.net.httpserver.HttpServer
import dev.whysoezzy.meet.config.GeocoderProperties
import org.junit.jupiter.api.Test
import org.springframework.web.client.RestClient
import tools.jackson.databind.ObjectMapper
import java.net.InetSocketAddress
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import ch.qos.logback.classic.Logger
import ch.qos.logback.classic.spi.ThrowableProxyUtil
import ch.qos.logback.core.read.ListAppender
import org.slf4j.LoggerFactory
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GeocodingServiceTest {
    @Test
    fun `crafted HTTP authority is rejected before sending a key to non-loopback transport`() {
        val calls = AtomicInteger()
        val server = server { calls.incrementAndGet(); eligible("55", "37") }
        val port = server.address.port
        for (base in listOf(
            "http://127.0.0.1:$port@localhost:$port",
            "http://127.0.0.1:$port@127.0.0.1:$port",
            "https://unwanted-user@127.0.0.1:$port",
        )) {
            val service = GeocodingService(
                RestClient.builder(), GeocoderProperties(true, "synthetic-secret-marker", base), ObjectMapper(),
            )
            try {
                assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
                assertEquals(0, calls.get())
            } finally {
                service.shutdown()
            }
        }
        server.stop(0)
    }

    @Test
    fun `Timepad failure logging does not disclose key address coordinates or provider text`() {
        val address = "Sensitivevenue, 1"
        val server = server(status = 500) { "PRIVATE-PROVIDER-PAYLOAD 12.345678901 34.567890123" }
        val service = service(server)
        val logger = LoggerFactory.getLogger(GeocodingService::class.java) as Logger
        val appender = ListAppender<ch.qos.logback.classic.spi.ILoggingEvent>().apply { start() }
        logger.addAppender(appender)
        try {
            assertNull(service.geocodeTimepad(address))
            val output = appender.list.joinToString("\n") {
                it.formattedMessage + it.throwableProxy?.let(ThrowableProxyUtil::asString).orEmpty()
            }
            assertTrue(output.contains("Geocoding request failed"))
            for (marker in listOf(address, "synthetic-secret-marker", "PRIVATE-PROVIDER-PAYLOAD",
                "12.345678901", "34.567890123")) {
                assertTrue(marker !in output, "private marker disclosed")
            }
        } finally {
            logger.detachAppender(appender)
            appender.stop()
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `slow drip body is cancelled at whole request deadline and admission recovers`() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val executor = Executors.newCachedThreadPool()
        server.executor = executor
        val cancelled = CountDownLatch(1)
        val calls = AtomicInteger()
        server.createContext("/search") { exchange ->
            exchange.responseHeaders.add("Content-Type", "application/json")
            if (calls.incrementAndGet() == 1) {
                exchange.sendResponseHeaders(200, 0)
                try {
                    exchange.responseBody.use { body ->
                        body.write('['.code)
                        body.flush()
                        repeat(120) {
                            Thread.sleep(100)
                            body.write(' '.code)
                            body.flush()
                        }
                    }
                } catch (_: java.io.IOException) {
                    cancelled.countDown()
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                } finally {
                    exchange.close()
                }
            } else {
                val response = eligible("55", "37").toByteArray()
                exchange.sendResponseHeaders(200, response.size.toLong())
                exchange.responseBody.use { it.write(response) }
            }
        }
        server.start()
        val service = service(server)
        try {
            val started = System.nanoTime()
            assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            assertTrue(elapsed in 9_000..12_000, "whole request deadline exceeded: $elapsed")
            assertTrue(cancelled.await(2, TimeUnit.SECONDS), "body subscription was not cancelled")
            assertEquals(Coordinates(55.0, 37.0), service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertEquals(2, calls.get())
        } finally {
            service.shutdown()
            server.stop(0)
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(2, TimeUnit.SECONDS))
        }
    }

    @Test
    fun `timepad accepts exact single venue and identical duplicate points only`() {
        val calls = AtomicInteger()
        val server = server { calls.incrementAndGet(); eligible(lat = "55.0", lon = "37.0") }
        val service = service(server)
        try {
            assertEquals(Coordinates(55.0, 37.0), service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertEquals(1, calls.get())
        } finally {
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `timepad request is constrained to russian detailed two-result diagnostic query`() {
        var rawQuery: String? = null
        val server = server(onRequest = { rawQuery = it.rawQuery }) {
            eligible(lat = "55.0", lon = "37.0")
        }
        val service = service(server)
        try {
            assertEquals(Coordinates(55.0, 37.0), service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            val query = rawQuery.orEmpty()
            listOf(
                "limit=2", "accept-language=ru", "countrycodes=ru", "addressdetails=1",
                "normalizeaddress=1", "normalizecity=0", "matchquality=1", "dedupe=0",
            ).forEach { assertTrue(query.contains(it), "missing query parameter $it") }
            assertTrue(query.contains("Москва") || query.contains("%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0"))
            assertTrue(query.contains("Россия") || query.contains("%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D1%8F"))
        } finally {
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `legacy geocode remains coordinate-only and uncached`() {
        val calls = AtomicInteger()
        val server = server { calls.incrementAndGet(); """[{"lat":"55","lon":"37"}]""" }
        val service = service(server)
        try {
            assertEquals(Coordinates(55.0, 37.0), service.geocode("same"))
            Thread.sleep(1_150)
            assertEquals(Coordinates(55.0, 37.0), service.geocode("same"))
            assertEquals(2, calls.get())
        } finally {
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `ambiguous points fail closed and immediate calls are skipped`() {
        val calls = AtomicInteger()
        val server = server {
            calls.incrementAndGet()
            eligible(lat = "55.0", lon = "37.0").dropLast(1) +
                "," + eligible(lat = "55.001", lon = "37.0").removePrefix("[")
        }
        val service = service(server)
        try {
            assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertEquals(1, calls.get())
        } finally {
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `disabled configuration makes no provider request`() {
        val calls = AtomicInteger()
        val server = server { calls.incrementAndGet(); "[]" }
        val service = GeocodingService(
            RestClient.builder(),
            GeocoderProperties(enabled = false, apiKey = "synthetic", baseUrl = "http://127.0.0.1:${server.address.port}"),
            ObjectMapper(),
        )
        try {
            assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertEquals(0, calls.get())
        } finally {
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `missing key makes no provider request`() {
        val calls = AtomicInteger()
        val server = server { calls.incrementAndGet(); "[]" }
        val service = GeocodingService(
            RestClient.builder(),
            GeocoderProperties(enabled = true, apiKey = "", baseUrl = "http://127.0.0.1:${server.address.port}"),
            ObjectMapper(),
        )
        try {
            assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertEquals(0, calls.get())
        } finally {
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `invalid status content type json shape and candidate metadata fail closed`() {
        val invalidBodies = listOf(
            "not-json",
            "[]",
            "[null]",
            eligible(lat = "55", lon = "37") + " []",
            """{"lat":"55","lon":"37"}""",
            eligible(lat = "55", lon = "37").removeSuffix("]") + "," +
                eligible(lat = "55", lon = "37").removePrefix("[") + "," +
                eligible(lat = "55", lon = "37").removePrefix("["),
            eligible(lat = "55", lon = "37").replace("\"matchcode\":\"exact\"", "\"matchcode\":\"fallback\""),
            eligible(lat = "55", lon = "37").replace("\"country_code\":\"ru\"", "\"country_code\":\"us\""),
            eligible(lat = "55", lon = "37").replace("\"city\":\"Москва\"", "\"city\":\"Химки\""),
            eligible(lat = "55", lon = "37").replace("\"matchtype\":\"point\"", "\"matchtype\":\"interpolated\""),
            eligible(lat = "55", lon = "37").replace("\"matchlevel\":\"building\"", "\"matchlevel\":\"street\""),
            eligible(lat = "55", lon = "37").replace("\"lat\":\"55\"", "\"lat\":\"NaN\""),
            eligible(lat = "55", lon = "37").replace("\"lat\":\"55\"", "\"lat\":\"91\""),
            eligible(lat = "55", lon = "37").replace("\"lon\":\"37\"", "\"lon\":\"181\""),
            eligible(lat = "55", lon = "37").replace("\"lat\":\"55\"", "\"lat\":\"0\"")
                .replace("\"lon\":\"37\"", "\"lon\":\"0\""),
        )
        invalidBodies.forEach { body ->
            val server = server { body }
            val service = service(server)
            try {
                assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"), body.take(60))
            } finally {
                service.shutdown()
                server.stop(0)
            }
        }
    }

    @Test
    fun `oversized duplicate deep and encoded response bodies fail closed`() {
        val bodies = listOf(
            "[" + " ".repeat(1_048_577) + "]",
            """[{"lat":"55","lat":"55"}]""",
            """[{"unknown":${"[".repeat(20)}0${"]".repeat(20)}}]""",
            """[{"unknown":"${"x".repeat(16_385)}"}]""",
        )
        bodies.forEach { body ->
            val server = server { body }
            val service = service(server)
            try {
                assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            } finally {
                service.shutdown()
                server.stop(0)
            }
        }
    }

    @Test
    fun `http errors redirect and unsupported encoding fail closed`() {
        listOf(
            "malformed" to server { "not-json" },
            "429" to server(status = 429) { "rate limited" },
            "redirect" to server(status = 302, location = "/search") { "" },
            "encoding" to server(contentEncoding = "gzip") { eligible(lat = "55", lon = "37") },
            "content-type" to server(contentType = "text/plain") { eligible(lat = "55", lon = "37") },
        ).forEach { (scenario, server) ->
            val service = service(server)
            try {
                assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"), scenario)
            } finally {
                service.shutdown()
                server.stop(0)
            }
        }
    }

    @Test
    fun `a concurrent request is rejected without waiting or queueing`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val calls = AtomicInteger()
        val server = server {
            calls.incrementAndGet()
            entered.countDown()
            release.await(3, TimeUnit.SECONDS)
            eligible(lat = "55.0", lon = "37.0")
        }
        val service = service(server)
        val first = Thread { service.geocodeTimepad("Новодмитровская, 1, стр 1") }
        try {
            first.start()
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertNull(service.geocode("legacy concurrent address"))
            assertEquals(1, calls.get())
        } finally {
            release.countDown()
            first.join(2_000)
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `complete http body deadline cancels stalled response`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val server = server(status = 0) {
            entered.countDown()
            release.await(12, TimeUnit.SECONDS)
            eligible(lat = "55.0", lon = "37.0")
        }
        val service = service(server)
        try {
            assertNull(service.geocodeTimepad("Новодмитровская, 1, стр 1"))
            assertTrue(entered.await(1, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            service.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `interrupted request restores caller interrupt flag`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val server = server(status = 0) {
            entered.countDown()
            release.await(12, TimeUnit.SECONDS)
            eligible(lat = "55.0", lon = "37.0")
        }
        val service = service(server)
        val caller = Thread {
            service.geocodeTimepad("Новодмитровская, 1, стр 1")
            if (Thread.currentThread().isInterrupted) interrupted.countDown()
        }
        try {
            caller.start()
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            caller.interrupt()
            assertTrue(interrupted.await(2, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            caller.join(2_000)
            service.shutdown()
            server.stop(0)
        }
    }

    private fun service(server: HttpServer) = GeocodingService(
        RestClient.builder(),
        GeocoderProperties(
            enabled = true,
            apiKey = "synthetic-secret-marker",
            baseUrl = "http://127.0.0.1:${server.address.port}",
        ),
        ObjectMapper(),
    )

    private fun server(
        status: Int = 200,
        contentType: String = "application/json",
        contentEncoding: String? = null,
        location: String? = null,
        onRequest: (URI) -> Unit = {},
        body: () -> String,
    ): HttpServer {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/search") { exchange ->
            exchange.requestBody.close()
            onRequest(exchange.requestURI)
            val response = body().toByteArray()
            exchange.responseHeaders.add("Content-Type", contentType)
            contentEncoding?.let { exchange.responseHeaders.add("Content-Encoding", it) }
            location?.let { exchange.responseHeaders.add("Location", it) }
            if (status == 0) {
                exchange.sendResponseHeaders(200, response.size.toLong())
                exchange.responseBody.use { it.write(response) }
            } else if (status in 300..399 || status == 429) {
                exchange.sendResponseHeaders(status, -1)
                exchange.close()
            } else {
                exchange.sendResponseHeaders(status, response.size.toLong())
                exchange.responseBody.use { it.write(response) }
            }
        }
        server.start()
        return server
    }

    private fun eligible(lat: String, lon: String) =
        """[{"lat":"$lat","lon":"$lon","address":{"road":"Новодмитровская улица","house_number":"1 стр 1","country_code":"ru","city":"Москва"},"matchquality":{"matchcode":"exact","matchtype":"point","matchlevel":"building"}}]"""
}
