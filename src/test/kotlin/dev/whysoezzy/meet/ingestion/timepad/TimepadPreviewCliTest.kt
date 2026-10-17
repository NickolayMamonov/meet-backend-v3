package dev.whysoezzy.meet.ingestion.timepad

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tools.jackson.module.kotlin.jacksonObjectMapper
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.io.PrintStream
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.HexFormat
import kotlin.test.*

class TimepadPreviewCliTest {
    @TempDir
    lateinit var dir: Path
    private val json = jacksonObjectMapper()
    private val event = """{"id":1,"name":"Backend","starts_at":"2026-10-18T12:00:00Z",
        "url":"https://club.timepad.ru/event/1/","location":{"city":"Москва","address":"Онлайн"}}"""
    private val source get() = """{"total":1,"values":[$event]}"""
    private fun hash(bytes: ByteArray) = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private fun review(bytes: ByteArray, entry: String = reviewedEntry(), hash: String = hash(bytes)) =
        """{"schemaVersion":1,"inputSha256":"$hash","events":[$entry]}"""
    private fun reviewedEntry(id: Long = 1) =
        """{"id":$id,"adultProfessional":true,"notTest":true,"format":"ONLINE","locationVerified":true}"""
    private data class Run(val exit: Int, val out: String, val err: String)
    private fun run(args: Array<String>): Run {
        val out = ByteArrayOutputStream()
        val err = ByteArrayOutputStream()
        val exit = PrintStream(out, true, Charsets.UTF_8).use { stdout ->
            PrintStream(err, true, Charsets.UTF_8).use { stderr ->
                TimepadPreviewCli.run(args, stdout, stderr)
            }
        }
        return Run(exit, out.toString(Charsets.UTF_8), err.toString(Charsets.UTF_8))
    }
    private fun args(input: Path, reviewed: Path) = arrayOf("--input", input.toString(), "--reviewed",
        reviewed.toString(), "--as-of", "2026-10-17T00:00:00Z")
    private fun execute(bytes: ByteArray = source.toByteArray(), reviewed: String = review(bytes)): Run {
        val input = dir.resolve("source.json")
        val reviewPath = dir.resolve("reviewed.json")
        Files.write(input, bytes)
        Files.writeString(reviewPath, reviewed)
        val beforeReview = Files.readAllBytes(reviewPath)
        val result = run(args(input, reviewPath))
        assertContentEquals(bytes, Files.readAllBytes(input))
        assertContentEquals(beforeReview, Files.readAllBytes(reviewPath))
        return result
    }
    private fun failure(code: String, bytes: ByteArray = source.toByteArray(), reviewed: String = review(bytes)) {
        val result = execute(bytes, reviewed)
        assertEquals(2, result.exit, result.toString())
        assertEquals("", result.out)
        assertEquals("$code\n", result.err.replace("\r\n", "\n"))
        assertFalse(result.err.contains("Exception"))
    }

    @Test
    fun `CLI completes without application context or credentials and reports exact reproducible hashes`() {
        val first = execute()
        assertEquals(0, first.exit, first.err)
        assertEquals("", first.err)
        assertEquals(first, execute())
        val report = json.readTree(first.out)
        assertEquals("OFFLINE_CANDIDATES_ONLY", report.path("mode").stringValue())
        assertFalse(report.path("databaseCompared").booleanValue())
        assertEquals(hash(source.toByteArray()), report.path("inputSha256").stringValue())
        assertEquals(hash(review(source.toByteArray()).toByteArray()), report.path("reviewSha256").stringValue())
        assertEquals(1, report.path("counts").path("candidates").intValue())
        assertEquals("CANDIDATE", report.path("results")[0].path("status").stringValue())
        assertEquals(setOf("source.json", "reviewed.json"),
            Files.list(dir).use { paths -> paths.map { it.fileName.toString() }.toList().toSet() })
        for (key in listOf("created", "updated", "skipped", "create", "update")) {
            assertFalse(report.path("counts").has(key))
        }
    }

    @Test
    fun `valid zero-candidate run is success and empty selection is not approval`() {
        val bytes = source.replace("2026-10-18T12:00:00Z", "2026-10-16T12:00:00Z").toByteArray()
        val result = execute(bytes)
        assertEquals(0, result.exit)
        assertEquals(0, json.readTree(result.out).path("counts").path("candidates").intValue())
        failure("INVALID_REVIEW_SCHEMA", """{"values":[]}""".toByteArray(),
            review("""{"values":[]}""".toByteArray(), entry = ""))
        failure("REVIEWED_ID_NOT_FOUND", """{"values":[]}""".toByteArray())
    }

    @Test
    fun `arguments reject duplicates unknown flags URLs missing values and non UTC time`() {
        val valid = args(dir.resolve("a"), dir.resolve("b"))
        val invalid = listOf(
            emptyArray(), arrayOf("--input"), valid + arrayOf("--extra", "x"),
            arrayOf("--input", "x", "--input", "y", "--as-of", "2026-10-17T00:00:00Z"),
            valid.copyOf().apply { this[0] = "--fetch" },
            valid.copyOf().apply { this[1] = "https://timepad.ru/events.json" },
            valid.copyOf().apply { this[1] = "\\\\server\\share\\source.json" },
            valid.copyOf().apply { this[1] = "//server/share/source.json" },
            valid.copyOf().apply { this[5] = "2026-10-17T03:00:00+03:00" },
            valid.copyOf().apply { this[5] = "not-a-date" },
            valid.copyOf().apply { this[5] = "+1000000000-12-31T23:59:59.999999999Z" },
            valid.copyOf().apply { this[1] = " " },
        )
        invalid.forEach {
            val result = run(it)
            assertEquals(2, result.exit)
            assertEquals("", result.out)
            assertEquals("INVALID_ARGUMENTS", result.err.trim())
        }
        assertEquals("INPUT_IO", run(valid).err.trim())
        Files.createDirectory(dir.resolve("a"))
        assertEquals("INPUT_IO", run(valid).err.trim())
    }

    @Test
    fun `strict UTF8 one-document JSON duplicate-key and nesting failures emit no partial report`() {
        val invalid = listOf(
            byteArrayOf(0xc3.toByte(), 0x28),
            byteArrayOf(0xff.toByte(), 0xfe.toByte(), 0x7b, 0),
            "".toByteArray(), "   ".toByteArray(), "{".toByteArray(),
            "$source {}".toByteArray(),
            """{"values":[],"values":[]}""".toByteArray(),
            source.replace(""""id":1""", """"id":1,"id":1""").toByteArray(),
            ("""{"values":[],"unknown":""" + "[".repeat(65) + "0" + "]".repeat(65) + "}").toByteArray(),
        )
        invalid.forEach { failure("INVALID_JSON", it) }
        failure("INVALID_JSON", reviewed = review(source.toByteArray()) + "{}")
        failure("INVALID_JSON", reviewed = review(source.toByteArray()).replace(
            """"notTest":true""", """"notTest":true,"notTest":true"""))
    }

    @Test
    fun `source schema is strict before DTO conversion without coercion`() {
        val invalid = listOf("null", "[]", """{"total":0}""", """{"values":null}""", """{"values":{}}""",
            """{"total":-1,"values":[]}""", """{"total":0,"values":[$event]}""",
            """{"total":"1","values":[$event]}""", """{"total":null,"values":[]}""",
            """{"values":[null]}""", """{"values":[{}]}""")
        invalid.forEach { failure("INVALID_SOURCE_SCHEMA", it.toByteArray()) }
        for (id in listOf("0", "-1", "1.0", "\"1\"", "null", "true", "9223372036854775808")) {
            failure("INVALID_SOURCE_SCHEMA", source.replace(""""id":1""", """"id":$id""").toByteArray())
        }
        for (replacement in listOf(""""name":null""", """"name":42""", """"name":true""")) {
            failure("INVALID_SOURCE_SCHEMA", source.replace(""""name":"Backend"""", replacement).toByteArray())
        }
        for (field in listOf("starts_at", "ends_at", "url", "description_short", "description_html")) {
            val changed = """{"values":[{"id":1,"$field":42}]}""".toByteArray()
            failure("INVALID_SOURCE_SCHEMA", changed)
        }
        failure("DUPLICATE_SOURCE_ID", """{"values":[$event,$event]}""".toByteArray())
        assertEquals(0, execute("""{"values":[$event],"ignored":{"x":true}}""".toByteArray()).exit)
    }

    @Test
    fun `review must attest exact snapshot all flags and each existing unique positive ID`() {
        failure("REVIEW_HASH_MISMATCH", reviewed = review(source.toByteArray(), hash = "0".repeat(64)))
        for (hash in listOf("A".repeat(64), "not-a-hash")) {
            failure("INVALID_REVIEW_SCHEMA", reviewed = review(source.toByteArray(), hash = hash))
        }
        val valid = review(source.toByteArray())
        for (flag in listOf("adultProfessional", "notTest", "locationVerified")) {
            for (value in listOf("false", "\"true\"", "null", "1")) {
                failure("INVALID_REVIEW_SCHEMA", reviewed = valid.replace("\"$flag\":true", "\"$flag\":$value"))
            }
            failure("INVALID_REVIEW_SCHEMA", reviewed = valid.replace(Regex(",?\"$flag\":true,?")) {
                if (it.value.startsWith(",") && it.value.endsWith(",")) "," else ""
            })
        }
        for (review in listOf(
            "null", "[]", valid.replace("\"schemaVersion\":1", "\"schemaVersion\":\"1\""),
            valid.replace("\"schemaVersion\":1", "\"schemaVersion\":2"),
            valid.replace("\"events\":[", "\"extra\":true,\"events\":["),
            valid.replace("\"id\":1", "\"id\":0"), valid.replace("\"id\":1", "\"id\":\"1\""),
            valid.replace("\"format\":\"ONLINE\"", "\"format\":\"UNKNOWN\""),
            valid.replace("\"format\":\"ONLINE\"", "\"format\":null"),
            valid.replace("\"notTest\":true", "\"notTest\":true,\"extra\":1"),
            valid.replace("\"events\":[", "\"events\":null,\"ignored\":["),
            review(source.toByteArray(), entry = reviewedEntry() + "," + reviewedEntry()),
        )) failure("INVALID_REVIEW_SCHEMA", reviewed = review)
        failure("REVIEWED_ID_NOT_FOUND", reviewed = review(source.toByteArray(), reviewedEntry(2)))
    }

    @Test
    fun `byte caps enforced exactly for both streams`() {
        val sourceBytes = source.toByteArray()
        val padded = sourceBytes + ByteArray(TimepadPreviewCli.SOURCE_LIMIT - sourceBytes.size) { ' '.code.toByte() }
        assertEquals(0, execute(padded).exit)
        failure("INPUT_TOO_LARGE", padded + ' '.code.toByte())
        val review = review(sourceBytes)
        val paddedReview = review + " ".repeat(TimepadPreviewCli.REVIEW_LIMIT - review.toByteArray().size)
        assertEquals(0, execute(reviewed = paddedReview).exit)
        failure("INPUT_TOO_LARGE", reviewed = paddedReview + " ")
    }

    @Test
    fun `500 records accepted and above either count cap rejected`() {
        val events = (1..500).joinToString(",") { id ->
            event.replace(""""id":1""", """"id":$id""")
        }
        val bytes = """{"total":500,"values":[$events]}""".toByteArray()
        val result = execute(bytes)
        assertEquals(0, result.exit, result.err)
        assertEquals(500, json.readTree(result.out).path("counts").path("input").intValue())
        failure("TOO_MANY_EVENTS", """{"values":[$events,$event]}""".toByteArray())
        val reviewed500 = (1L..500L).joinToString(",") { reviewedEntry(it) }
        assertEquals(0, execute(bytes, review(bytes, reviewed500)).exit)
        failure("TOO_MANY_EVENTS", bytes, review(bytes, reviewed500 + "," + reviewedEntry()))
    }

    @Test
    fun `output failures return one without leaking exception details`() {
        assertEquals(0, execute().exit)
        val err = ByteArrayOutputStream()
        val failingOut = PrintStream(object : OutputStream() {
            override fun write(value: Int) {
                throw IOException("secret-output-marker")
            }
        })
        val exit = failingOut.use { out ->
            PrintStream(err, true, Charsets.UTF_8).use { stderr ->
                TimepadPreviewCli.run(args(dir.resolve("source.json"), dir.resolve("reviewed.json")), out, stderr)
            }
        }
        assertEquals(1, exit)
        assertEquals("INTERNAL_ERROR", err.toString(Charsets.UTF_8).trim())
    }

    @Test
    fun `paths containing spaces and reordered flags need no shell parsing`() {
        assertEquals(0, execute().exit)
        val spaced = Files.createDirectory(dir.resolve("paths with spaces"))
        val input = Files.copy(dir.resolve("source.json"), spaced.resolve("source snapshot.json"))
        val reviewed = Files.copy(dir.resolve("reviewed.json"), spaced.resolve("reviewed selection.json"))
        val result = run(arrayOf("--as-of", "2026-10-17T00:00:00Z", "--reviewed", reviewed.toString(),
            "--input", input.toString()))
        assertEquals(0, result.exit, result.err)
    }

    @Test
    fun `JSON output is UTF8 even when supplied stdout uses Windows native encoding`() {
        assertEquals(0, execute().exit)
        val bytes = ByteArrayOutputStream()
        val err = ByteArrayOutputStream()
        val exit = PrintStream(bytes, true, charset("windows-1251")).use { nativeOut ->
            TimepadPreviewCli.run(args(dir.resolve("source.json"), dir.resolve("reviewed.json")), nativeOut, err)
        }
        assertEquals(0, exit)
        assertEquals("", err.toString(Charsets.UTF_8))
        assertEquals("Онлайн", json.readTree(bytes.toString(Charsets.UTF_8))
            .path("results")[0].path("normalized").path("address").stringValue())
    }
}
