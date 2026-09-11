package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.mock.env.MockEnvironment
import java.nio.file.Files
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class FirebasePushConfigurationTest {
    @Test
    fun `provider bean is conditional on provider enablement and missing push provider`() {
        val method = FirebasePushConfiguration::class.java.getDeclaredMethod(
            "firebasePushProvider",
            PushProperties::class.java,
            org.springframework.core.env.ConfigurableEnvironment::class.java,
        )
        val property = method.getAnnotation(ConditionalOnProperty::class.java)
        assertEquals("provider-enabled", property.name.single())
        assertEquals("true", property.havingValue)
        assertContentEquals(
            arrayOf("dev.whysoezzy.meet.service.push.PushProvider"),
            method.getAnnotation(ConditionalOnMissingBean::class.java).value.map { it.java.name }.toTypedArray(),
        )
    }

    @Test
    fun `enabled provider rejects missing and malformed credentials with static configuration error`() {
        val configuration = FirebasePushConfiguration()
        val environment = MockEnvironment()
        val missing = assertFailsWith<IllegalStateException> {
            configuration.firebasePushProvider(
                PushProperties(providerEnabled = true, credentialsFile = Files.createTempDirectory("push-test")
                    .resolve("missing.json").toString()),
                environment,
            )
        }
        assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, missing.message)

        val malformed = Files.createTempFile("push-test", ".json")
        try {
            Files.writeString(malformed, "{}")
            val failure = assertFailsWith<IllegalStateException> {
                configuration.firebasePushProvider(
                    PushProperties(providerEnabled = true, credentialsFile = malformed.toString()),
                    environment,
                )
            }
            assertEquals(PushRuntimeSettings.INVALID_CONFIGURATION, failure.message)
        } finally {
            Files.deleteIfExists(malformed)
        }
    }
}
