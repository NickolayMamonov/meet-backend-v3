package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.dto.PushDiagnosticRequest
import dev.whysoezzy.meet.api.dto.PushInstallationRequest
import dev.whysoezzy.meet.api.error.PayloadTooLargeException
import org.springframework.http.HttpInputMessage
import org.springframework.http.MediaType
import org.springframework.http.converter.AbstractHttpMessageConverter
import org.springframework.http.converter.HttpMessageNotReadableException
import tools.jackson.core.StreamReadFeature
import tools.jackson.databind.DeserializationFeature
import tools.jackson.databind.ObjectMapper

/**
 * Strict input boundary for the two additive push request types. The global
 * Jackson converter remains unchanged so legacy request compatibility is
 * preserved.
 */
class PushRequestMessageConverter(
    private val objectMapper: ObjectMapper,
) : AbstractHttpMessageConverter<Any>(MediaType.APPLICATION_JSON) {
    private val strictReader = objectMapper.reader(
            DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES,
            DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES,
            DeserializationFeature.FAIL_ON_MISSING_CREATOR_PROPERTIES,
            DeserializationFeature.FAIL_ON_NULL_CREATOR_PROPERTIES,
            DeserializationFeature.FAIL_ON_TRAILING_TOKENS,
        ).with(StreamReadFeature.STRICT_DUPLICATE_DETECTION)

    override fun supports(clazz: Class<*>): Boolean =
        clazz == PushInstallationRequest::class.java || clazz == PushDiagnosticRequest::class.java

    override fun readInternal(clazz: Class<out Any>, inputMessage: HttpInputMessage): Any {
        val body = inputMessage.body.readNBytes(MAX_BODY_BYTES + 1)
        if (body.size > MAX_BODY_BYTES) throw PayloadTooLargeException()
        try {
            validateShape(clazz, body)
            return strictReader.forType(clazz).readValue(body)
        } catch (exception: PayloadTooLargeException) {
            throw exception
        } catch (_: Exception) {
            throw HttpMessageNotReadableException("Invalid request", inputMessage)
        }
    }

    override fun writeInternal(any: Any, outputMessage: org.springframework.http.HttpOutputMessage) {
        objectMapper.writeValue(outputMessage.body, any)
    }

    private fun validateShape(clazz: Class<out Any>, body: ByteArray) {
        val root = strictReader.readTree(body)
        require(root.isObject) { "request must be an object" }
        val expected = if (clazz == PushInstallationRequest::class.java) {
            setOf("fid")
        } else {
            setOf("userId", "installationId", "meetingId", "reminderOffsetMinutes", "mode")
        }
        val actual = root.propertyNames().toSet()
        require(actual == expected) { "request fields are invalid" }
        expected.forEach { name ->
            val node = root.get(name) as tools.jackson.databind.JsonNode
            require(node != null && !node.isNull) { "request field is required" }
            if (name == "fid" || name == "installationId" || name == "mode") {
                require(node.isTextual) { "request field must be a string" }
            } else {
                require(node.isIntegralNumber) { "request field must be an integer" }
            }
        }
    }

    private companion object {
        const val MAX_BODY_BYTES = 16 * 1024
    }
}
