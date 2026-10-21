package dev.whysoezzy.meet.ingestion.timepad

import dev.whysoezzy.meet.config.TimepadProperties
import jakarta.annotation.PreDestroy
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.stereotype.Component
import tools.jackson.core.StreamReadConstraints
import tools.jackson.core.StreamReadFeature
import tools.jackson.core.json.JsonFactory
import tools.jackson.databind.ObjectMapper
import tools.jackson.databind.json.JsonMapper
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.ByteBuffer
import java.time.Duration
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Flow
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

@Component
@ConditionalOnProperty(prefix = "app.timepad", name = ["enabled"], havingValue = "true")
class TimepadHttpClient(
    private val properties: TimepadProperties,
    mapper: ObjectMapper,
) {
    private val executor: ExecutorService = Executors.newFixedThreadPool(2)
    private val client = HttpClient.newBuilder()
        .executor(executor)
        .connectTimeout(Duration.ofSeconds(3))
        .followRedirects(HttpClient.Redirect.NEVER)
        .version(HttpClient.Version.HTTP_1_1)
        .build()
    private val strictFactory = mapper.tokenStreamFactory().rebuild()
        .streamReadConstraints(
            StreamReadConstraints.builder()
                .maxNestingDepth(MAX_JSON_DEPTH)
                .maxStringLength(MAX_JSON_STRING_LENGTH)
                .build(),
        )
        .build()
    private val strictMapper: ObjectMapper = JsonMapper.builder(strictFactory as JsonFactory)
        .addModules(mapper.registeredModules())
        .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
        .build()
    private val strictReader = strictMapper.reader()

    fun fetch(uri: URI): TimepadEventsResponse {
        require(uri.scheme == "https" || properties.baseUrl.startsWith("http://127.0.0.1:")) {
            "Timepad transport requires HTTPS"
        }
        val request = HttpRequest.newBuilder(uri)
            .timeout(REQUEST_TIMEOUT)
            .header("Accept", "application/json")
            .header("Accept-Encoding", "identity")
            .apply { if (properties.token.isNotBlank()) header("Authorization", "Bearer ${properties.token}") }
            .GET()
            .build()
        val subscriber = BoundedBodySubscriber(MAX_BODY_BYTES)
        val bodyHandler = HttpResponse.BodyHandler<ByteArray> { response ->
            val encoding = response.headers().firstValue("Content-Encoding").orElse("identity")
            if (!encoding.equals("identity", ignoreCase = true)) {
                throw IOException("unsupported_content_encoding")
            }
            subscriber
        }
        val responseFuture = client.sendAsync(request, bodyHandler)
        return try {
            val response = responseFuture.get(REQUEST_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)
            if (response.statusCode() != 200) throw IOException("http_status")
            val contentType = response.headers().firstValue("Content-Type").orElse("")
            if (!contentType.substringBefore(';').trim().equals("application/json", ignoreCase = true)) {
                throw IOException("content_type")
            }
            try {
                strictMapper.readValue(response.body(), TimepadEventsResponse::class.java)
            } catch (exception: Exception) {
                throw IOException("response_parse_failed", exception)
            }
        } catch (exception: TimeoutException) {
            responseFuture.cancel(true)
            subscriber.cancel()
            throw IOException("request_timeout", exception)
        } catch (exception: InterruptedException) {
            responseFuture.cancel(true)
            subscriber.cancel()
            Thread.currentThread().interrupt()
            throw IOException("request_interrupted", exception)
        } catch (exception: ExecutionException) {
            subscriber.cancel()
            throw IOException("request_failed", exception.cause)
        }
    }

    @PreDestroy
    fun shutdown() {
        executor.shutdownNow()
        if (!executor.awaitTermination(2, TimeUnit.SECONDS)) {
            throw IllegalStateException("Timepad HTTP executor did not stop")
        }
    }

    private class BoundedBodySubscriber(
        private val limit: Int,
    ) : HttpResponse.BodySubscriber<ByteArray> {
        private val result = CompletableFuture<ByteArray>()
        private val output = ByteArrayOutputStream()
        @Volatile private var subscription: Flow.Subscription? = null

        override fun getBody(): CompletionStage<ByteArray> = result

        override fun onSubscribe(value: Flow.Subscription) {
            subscription = value
            value.request(1)
        }

        override fun onNext(items: List<ByteBuffer>) {
            try {
                items.forEach { buffer ->
                    val size = buffer.remaining()
                    if (output.size() + size > limit) {
                        subscription?.cancel()
                        result.completeExceptionally(IOException("response_too_large"))
                        return
                    }
                    val bytes = ByteArray(size)
                    buffer.get(bytes)
                    output.write(bytes)
                }
                if (!result.isDone) subscription?.request(1)
            } catch (exception: Exception) {
                subscription?.cancel()
                result.completeExceptionally(IOException("response_read_failed", exception))
            }
        }

        override fun onError(throwable: Throwable) {
            result.completeExceptionally(throwable)
        }

        override fun onComplete() {
            result.complete(output.toByteArray())
        }

        fun cancel() {
            subscription?.cancel()
            result.cancel(true)
        }
    }

    private companion object {
        val REQUEST_TIMEOUT: Duration = Duration.ofSeconds(10)
        const val MAX_BODY_BYTES = 1_048_576
        const val MAX_JSON_DEPTH = 16
        const val MAX_JSON_STRING_LENGTH = 16_384
    }
}
