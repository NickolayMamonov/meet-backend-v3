package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.config.GeocoderProperties
import jakarta.annotation.PreDestroy
import mu.KotlinLogging
import org.springframework.web.client.RestClient
import org.springframework.stereotype.Service
import tools.jackson.core.StreamReadConstraints
import tools.jackson.core.StreamReadFeature
import tools.jackson.core.json.JsonFactory
import tools.jackson.databind.ObjectMapper
import tools.jackson.databind.DeserializationFeature
import tools.jackson.databind.json.JsonMapper
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Flow
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong

data class Coordinates(val latitude: Double, val longitude: Double)

@Service
class GeocodingService(
    @Suppress("UNUSED_PARAMETER") restClientBuilder: RestClient.Builder,
    private val props: GeocoderProperties,
    mapper: ObjectMapper = ObjectMapper(),
) {
    private val logger = KotlinLogging.logger {}
    private val executor: ExecutorService = Executors.newFixedThreadPool(2)
    private val client = HttpClient.newBuilder()
        .executor(executor)
        .connectTimeout(Duration.ofSeconds(3))
        .followRedirects(HttpClient.Redirect.NEVER)
        .version(HttpClient.Version.HTTP_1_1)
        .build()
    private val factory = mapper.tokenStreamFactory().rebuild()
        .streamReadConstraints(
            StreamReadConstraints.builder().maxNestingDepth(16).maxStringLength(16_384).build(),
        ).build()
    private val strictMapper = JsonMapper.builder(factory as JsonFactory)
        .addModules(mapper.registeredModules())
        .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
        .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
        .enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
        .build()
    private val admission = Semaphore(1)
    private val lastRequestNanos = AtomicLong(0)

    /** Legacy feed entry point; intentionally uncached so stale coordinates cannot accumulate. */
    fun geocode(address: String): Coordinates? {
        if (!available(address)) return null
        val deadline = System.nanoTime() + STAGE_TIMEOUT_NANOS
        return request(address, timepad = false, deadline)?.firstOrNull()?.coordinates
            ?.takeIf { System.nanoTime() < deadline }
    }

    /** Timepad-only strict venue match. */
    fun geocodeTimepad(address: String): Coordinates? {
        if (!available(address)) return null
        val deadline = System.nanoTime() + STAGE_TIMEOUT_NANOS
        val expected = TimepadVenueMatcher.parseInput(address) ?: return null
        val candidates = request(address, timepad = true, deadline) ?: return null
        return TimepadVenueMatcher.select(expected, candidates)?.takeIf { System.nanoTime() < deadline }
    }

    private fun available(address: String): Boolean {
        if (!props.enabled || props.apiKey.isBlank() || address.isBlank()) {
            logger.warn { "Geocoding skipped: unavailable configuration or address" }
            return false
        }
        return true
    }

    private fun request(
        address: String,
        timepad: Boolean,
        deadline: Long,
    ): List<TimepadVenueMatcher.Candidate>? {
        if (!admission.tryAcquire()) return null
        try {
            val now = System.nanoTime()
            val previous = lastRequestNanos.get()
            if (previous != 0L && now - previous < MIN_SPACING_NANOS) return null
            lastRequestNanos.set(now)

            if (now >= deadline) return null
            val query = if (timepad) "$address, Москва, Россия" else address
            fun encode(value: String) = URLEncoder.encode(value, StandardCharsets.UTF_8)
            val parameters = if (timepad) {
                "&limit=2&accept-language=ru&countrycodes=ru&addressdetails=1" +
                    "&normalizeaddress=1&normalizecity=0&matchquality=1&dedupe=0"
            } else {
                "&limit=1&accept-language=${encode(props.lang)}&normalizecity=1"
            }
            val uri = URI.create(
                "${props.baseUrl.trimEnd('/')}/search?key=${encode(props.apiKey)}" +
                    "&q=${encode(query)}&format=json$parameters",
            )
            require(uri.rawUserInfo == null && uri.host != null && uri.rawFragment == null &&
                (uri.scheme == "https" || (uri.scheme == "http" && uri.host == "127.0.0.1"))
            ) {
                "Geocoding transport requires HTTPS"
            }
            val timeout = Duration.ofNanos(minOf(REQUEST_TIMEOUT.toNanos(), deadline - System.nanoTime()))
            if (timeout.isNegative || timeout.isZero) return null
            val request = HttpRequest.newBuilder(uri)
                .timeout(timeout)
                .header("Accept", "application/json")
                .header("Accept-Encoding", "identity")
                .GET()
                .build()
            val bodySubscriber = BoundedBodySubscriber(MAX_BODY_BYTES)
            val future = client.sendAsync(request, HttpResponse.BodyHandler<ByteArray> { response ->
                if (!response.headers().firstValue("Content-Encoding").orElse("identity")
                        .equals("identity", ignoreCase = true)
                ) throw IOException("content_encoding")
                bodySubscriber
            })
            val response = try {
                future.get(timeout.toNanos(), TimeUnit.NANOSECONDS)
            } catch (exception: TimeoutException) {
                future.cancel(true)
                bodySubscriber.cancel()
                throw IOException("request_timeout", exception)
            } catch (exception: InterruptedException) {
                future.cancel(true)
                bodySubscriber.cancel()
                Thread.currentThread().interrupt()
                throw IOException("request_interrupted", exception)
            } catch (exception: ExecutionException) {
                bodySubscriber.cancel()
                throw IOException("request_failed", exception.cause)
            }
            if (response.statusCode() != 200) throw IOException("http_status")
            if (!response.headers().firstValue("Content-Type").orElse("")
                    .substringBefore(';').trim().equals("application/json", ignoreCase = true)
            ) return null
            if (System.nanoTime() >= deadline) return null
            val root = strictMapper.readTree(response.body()) ?: return null
            if (!root.isArray || root.size() > 2) return null
            return List(root.size()) { index -> TimepadVenueMatcher.parseCandidate(root[index]) }
                .takeIf { System.nanoTime() < deadline }
        } catch (exception: InterruptedException) {
            Thread.currentThread().interrupt()
            logger.warn { "Geocoding request interrupted" }
            return null
        } catch (_: Exception) {
            logger.warn { "Geocoding request failed" }
            return null
        } finally {
            admission.release()
        }
    }

    @PreDestroy
    fun shutdown() {
        client.shutdownNow()
        executor.shutdownNow()
        try {
            if (!client.awaitTermination(Duration.ofSeconds(2)) || !executor.awaitTermination(2, TimeUnit.SECONDS)) {
                throw IllegalStateException("Geocoding HTTP executor did not stop")
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private class BoundedBodySubscriber(private val limit: Int) : HttpResponse.BodySubscriber<ByteArray> {
        private val result = CompletableFuture<ByteArray>()
        private val output = ByteArrayOutputStream()
        @Volatile private var subscription: Flow.Subscription? = null
        override fun getBody(): CompletionStage<ByteArray> = result
        override fun onSubscribe(value: Flow.Subscription) {
            subscription = value
            if (result.isDone) value.cancel() else value.request(1)
        }
        override fun onNext(items: List<ByteBuffer>) {
            try {
                items.forEach { buffer ->
                    if (output.size() + buffer.remaining() > limit) {
                        subscription?.cancel()
                        result.completeExceptionally(IOException("response_too_large"))
                        return
                    }
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    output.write(bytes)
                }
                if (!result.isDone) subscription?.request(1)
            } catch (exception: Exception) {
                subscription?.cancel()
                result.completeExceptionally(IOException("response_read_failed", exception))
            }
        }
        override fun onError(throwable: Throwable) { result.completeExceptionally(throwable) }
        override fun onComplete() { result.complete(output.toByteArray()) }
        fun cancel() {
            subscription?.cancel()
            result.cancel(true)
        }
    }

    private companion object {
        val REQUEST_TIMEOUT = Duration.ofSeconds(10)
        const val MAX_BODY_BYTES = 1_048_576
        const val MIN_SPACING_NANOS = 1_100_000_000L
        const val STAGE_TIMEOUT_NANOS = 12_000_000_000L
    }
}
