package dev.whysoezzy.meet.ingestion.timepad

import com.sun.net.httpserver.HttpServer
import dev.whysoezzy.meet.config.TimepadProperties
import org.junit.jupiter.api.Test
import tools.jackson.databind.ObjectMapper
import java.io.IOException
import java.net.InetSocketAddress
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class TimepadHttpClientTest {
    @Test
    fun `bounded parser rejects oversized duplicate deep redirect and encoded responses`() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/large") { exchange ->
            val body = """{"total":0,"values":[]}""" + " ".repeat(1_048_600)
            val bytes = body.toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.createContext("/duplicate") { exchange ->
            val body = """{"total":0,"total":0,"values":[]}""".toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.createContext("/deep") { exchange ->
            val body = """{"total":0,"values":[],"unknown":${"[".repeat(20)}0${"]".repeat(20)}}""".toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.createContext("/redirect") { exchange ->
            exchange.responseHeaders.add("Location", "/good")
            exchange.sendResponseHeaders(302, -1)
            exchange.close()
        }
        server.createContext("/encoding") { exchange ->
            val bytes = """{"total":0,"values":[]}""".toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.responseHeaders.add("Content-Encoding", "gzip")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.createContext("/good") { exchange ->
            val bytes = """{"total":0,"values":[]}""".toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        val properties = TimepadProperties().apply { baseUrl = "http://127.0.0.1:${server.address.port}" }
        val transport = TimepadHttpClient(properties, ObjectMapper())
        try {
            listOf("/large", "/duplicate", "/deep", "/redirect", "/encoding").forEach { path ->
                assertFailsWith<IOException>(path) {
                    transport.fetch(URI("http://127.0.0.1:${server.address.port}$path"))
                }
            }
            assertEquals(emptyList(), transport.fetch(URI("http://127.0.0.1:${server.address.port}/good")).values)
        } finally {
            transport.shutdown()
            server.stop(0)
        }
    }

    @Test
    fun `absolute body timeout cancels stalled response and transport recovers`() {
        val slowStarted = CountDownLatch(1)
        val slowClosed = CountDownLatch(1)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/slow") { exchange ->
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, 0)
            slowStarted.countDown()
            try {
                exchange.responseBody.use { body ->
                    body.write("""{"total":""".toByteArray())
                    body.flush()
                    val trickle = ByteArray(64 * 1024) { ' '.code.toByte() }
                    repeat(100) {
                        body.write(trickle)
                        body.flush()
                        Thread.sleep(30)
                    }
                }
            } catch (_: IOException) {
                // A cancelled client may close the connection before the server finishes.
                slowClosed.countDown()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                slowClosed.countDown()
            }
        }
        server.createContext("/good") { exchange ->
            val bytes = """{"total":0,"values":[]}""".toByteArray()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()

        val properties = TimepadProperties().apply {
            baseUrl = "http://127.0.0.1:${server.address.port}"
        }
        val transport = TimepadHttpClient(properties, ObjectMapper())
        try {
            assertFailsWith<IOException> {
                transport.fetch(URI("http://127.0.0.1:${server.address.port}/slow"))
            }
            assertTrue(slowStarted.await(1, TimeUnit.SECONDS))
            assertTrue(slowClosed.await(5, TimeUnit.SECONDS))
            assertEquals(
                emptyList(),
                transport.fetch(URI("http://127.0.0.1:${server.address.port}/good")).values,
            )
        } finally {
            transport.shutdown()
            server.stop(0)
        }
    }
}
