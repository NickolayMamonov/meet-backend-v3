package dev.whysoezzy.meet.ingestion.timepad

import tools.jackson.core.JacksonException
import tools.jackson.core.StreamReadConstraints
import tools.jackson.core.StreamReadFeature
import tools.jackson.core.json.JsonFactory
import tools.jackson.databind.DeserializationFeature
import tools.jackson.databind.JsonNode
import tools.jackson.databind.json.JsonMapper
import tools.jackson.module.kotlin.KotlinModule
import java.io.IOException
import java.io.OutputStream
import java.io.PrintStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.InvalidPathException
import java.nio.file.Path
import java.security.MessageDigest
import java.time.DateTimeException
import java.time.Instant
import kotlin.system.exitProcess

internal enum class PreviewFailureCode {
    INVALID_ARGUMENTS, INPUT_IO, INPUT_TOO_LARGE, INVALID_JSON, INVALID_SOURCE_SCHEMA,
    INVALID_REVIEW_SCHEMA, TOO_MANY_EVENTS, DUPLICATE_SOURCE_ID, REVIEW_HASH_MISMATCH,
    REVIEWED_ID_NOT_FOUND,
}

internal class PreviewInputFailure(val code: PreviewFailureCode) : RuntimeException()

/** Standalone local-file entry point. Deliberately does not construct Spring or a provider. */
object TimepadPreviewCli {
    internal const val SOURCE_LIMIT = 5 * 1024 * 1024
    internal const val REVIEW_LIMIT = 256 * 1024
    private val mapper = JsonMapper.builder(
        JsonFactory.builder()
            .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
            .streamReadConstraints(StreamReadConstraints.builder().maxNestingDepth(64).build())
            .build(),
    ).addModule(KotlinModule.Builder().build())
        .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
        .build()

    fun run(args: Array<String>, out: OutputStream, err: OutputStream): Int =
        runUtf8(args, PrintStream(out, true, Charsets.UTF_8), PrintStream(err, true, Charsets.UTF_8))

    private fun runUtf8(args: Array<String>, out: PrintStream, err: PrintStream): Int = try {
        val options = arguments(args)
        val sourceBytes = readBounded(options.input, SOURCE_LIMIT)
        val reviewBytes = readBounded(options.reviewed, REVIEW_LIMIT)
        val source = parse(sourceBytes)
        val review = parse(reviewBytes)
        val events = sourceEvents(source)
        val inputHash = sha256(sourceBytes)
        val reviewed = reviewedEvents(review, inputHash, events.map { it.id }.toSet())
        val report = TimepadOfflinePreview().evaluate(events, reviewed, options.asOf, inputHash, sha256(reviewBytes))
        // Serialize before any output: a failed run must not emit a partial candidate report.
        val json = mapper.writeValueAsString(report)
        out.println(json)
        if (out.checkError()) {
            err.println("INTERNAL_ERROR")
            1
        } else 0
    } catch (failure: PreviewInputFailure) {
        err.println(failure.code.name)
        2
    } catch (_: Exception) {
        err.println("INTERNAL_ERROR")
        1
    }

    private data class Options(val input: Path, val reviewed: Path, val asOf: Instant)

    private fun arguments(args: Array<String>): Options {
        val flags = setOf("--input", "--reviewed", "--as-of")
        if (args.size != 6) fail(PreviewFailureCode.INVALID_ARGUMENTS)
        val values = linkedMapOf<String, String>()
        args.toList().chunked(2).forEach { (flag, value) ->
            if (flag !in flags || value.isBlank() || value.startsWith("--") || values.put(flag, value) != null) {
                fail(PreviewFailureCode.INVALID_ARGUMENTS)
            }
        }
        val asOfText = values.getValue("--as-of")
        if (!asOfText.endsWith("Z")) fail(PreviewFailureCode.INVALID_ARGUMENTS)
        val asOf = try {
            Instant.parse(asOfText).also { it.plusSeconds(30L * 24 * 60 * 60) }
        } catch (_: DateTimeException) {
            fail(PreviewFailureCode.INVALID_ARGUMENTS)
        }
        fun path(flag: String): Path {
            val text = values.getValue(flag)
            if (text.contains("://") || text.startsWith("\\\\") || text.startsWith("//")) {
                fail(PreviewFailureCode.INVALID_ARGUMENTS)
            }
            return try {
                Path.of(text)
            } catch (_: InvalidPathException) {
                fail(PreviewFailureCode.INVALID_ARGUMENTS)
            }
        }
        return Options(path("--input"), path("--reviewed"), asOf)
    }

    private fun readBounded(path: Path, cap: Int): ByteArray = try {
        if (!Files.isRegularFile(path) || !Files.isReadable(path)) fail(PreviewFailureCode.INPUT_IO)
        Files.newInputStream(path).use { stream ->
            stream.readNBytes(cap + 1).also {
                if (it.size > cap) fail(PreviewFailureCode.INPUT_TOO_LARGE)
            }
        }
    } catch (_: IOException) {
        fail(PreviewFailureCode.INPUT_IO)
    } catch (_: SecurityException) {
        fail(PreviewFailureCode.INPUT_IO)
    }

    private fun parse(bytes: ByteArray): JsonNode = try {
        val text = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
        mapper.readTree(text)?.takeUnless { it.isMissingNode } ?: fail(PreviewFailureCode.INVALID_JSON)
    } catch (_: CharacterCodingException) {
        fail(PreviewFailureCode.INVALID_JSON)
    } catch (_: JacksonException) {
        fail(PreviewFailureCode.INVALID_JSON)
    }

    private fun sourceEvents(root: JsonNode): List<TimepadEvent> {
        val code = PreviewFailureCode.INVALID_SOURCE_SCHEMA
        if (!root.isObject || !root.path("values").isArray) fail(code)
        val values = root.path("values")
        if (values.size() > 500) fail(PreviewFailureCode.TOO_MANY_EVENTS)
        val total = root.path("total")
        if (!total.isMissingNode && (!total.isIntegralNumber || !total.canConvertToLong() ||
                total.longValue() < values.size())) fail(code)
        val ids = mutableSetOf<Long>()
        return values.values().map { node ->
            if (!node.isObject) fail(code)
            val id = positiveId(node.path("id"), code)
            if (!ids.add(id)) fail(PreviewFailureCode.DUPLICATE_SOURCE_ID)
            val name = node.path("name")
            if (!name.isMissingNode && !name.isString) fail(code)
            for (key in listOf("description_short", "description_html", "starts_at", "ends_at", "url")) {
                val value = node.path(key)
                if (!value.isMissingNode && !value.isNull && !value.isString) fail(code)
            }
            try {
                mapper.treeToValue(node, TimepadEvent::class.java)
            } catch (_: JacksonException) {
                fail(code)
            }
        }
    }

    private fun reviewedEvents(root: JsonNode, inputHash: String, sourceIds: Set<Long>): List<ReviewedEvent> {
        val code = PreviewFailureCode.INVALID_REVIEW_SCHEMA
        if (!root.isObject || root.propertyNames().toSet() != setOf("schemaVersion", "inputSha256", "events")) {
            fail(code)
        }
        val version = root.path("schemaVersion")
        if (!version.isIntegralNumber || !version.canConvertToInt() || version.intValue() != 1) fail(code)
        val hash = root.path("inputSha256")
        if (!hash.isString || !Regex("[0-9a-f]{64}").matches(hash.stringValue())) fail(code)
        if (hash.stringValue() != inputHash) fail(PreviewFailureCode.REVIEW_HASH_MISMATCH)
        val events = root.path("events")
        if (!events.isArray || events.isEmpty) fail(code)
        if (events.size() > 500) fail(PreviewFailureCode.TOO_MANY_EVENTS)
        val ids = mutableSetOf<Long>()
        return events.values().map { node ->
            if (!node.isObject || node.propertyNames().toSet() !=
                setOf("id", "adultProfessional", "notTest", "format", "locationVerified")) fail(code)
            val id = positiveId(node.path("id"), code)
            if (!ids.add(id)) fail(code)
            for (flag in listOf("adultProfessional", "notTest", "locationVerified")) {
                if (!node.path(flag).isBoolean || !node.path(flag).booleanValue()) fail(code)
            }
            val format = node.path("format")
            if (!format.isString) fail(code)
            val reviewedFormat = ReviewedFormat.entries.find { it.name == format.stringValue() } ?: fail(code)
            if (id !in sourceIds) fail(PreviewFailureCode.REVIEWED_ID_NOT_FOUND)
            ReviewedEvent(id, reviewedFormat)
        }
    }

    private fun positiveId(node: JsonNode, code: PreviewFailureCode): Long {
        if (!node.isIntegralNumber || !node.canConvertToLong() || node.longValue() <= 0) fail(code)
        return node.longValue()
    }

    private fun sha256(bytes: ByteArray): String =
        java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun fail(code: PreviewFailureCode): Nothing = throw PreviewInputFailure(code)
}

fun main(args: Array<String>) {
    exitProcess(TimepadPreviewCli.run(args, System.out, System.err))
}
