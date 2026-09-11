package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PushPropertiesTest {
    @Test
    fun `push properties are disabled by default and redact credentials`() {
        val properties = PushProperties()

        assertFalse(properties.providerEnabled)
        assertFalse(properties.discoveryEnabled)
        assertFalse(properties.dispatchEnabled)
        assertFalse(properties.diagnosticEnabled)
        assertFalse(properties.maintenanceEnabled)
        assertEquals("meeting-1d258", properties.projectId)
        assertEquals("", properties.credentialsFile)
        assertEquals("PushProperties(redacted)", properties.toString())
    }

    @Test
    fun `runtime settings preserve enabled capabilities and imply maintenance`() {
        val settings = PushRuntimeSettings.from(
            PushProperties(
                providerEnabled = true,
                discoveryEnabled = true,
                dispatchEnabled = true,
                diagnosticEnabled = true,
                credentialsFile = "/run/secrets/firebase.json",
            ),
        )

        assertTrue(settings.providerEnabled)
        assertTrue(settings.discoveryEnabled)
        assertTrue(settings.dispatchEnabled)
        assertTrue(settings.diagnosticEnabled)
        assertTrue(settings.maintenanceEnabled)
        assertTrue(settings.maintenanceAdmissionEnabled)
    }

    @Test
    fun `provider capabilities require credentials and a valid project id`() {
        assertFailsWith<IllegalArgumentException> {
            PushRuntimeSettings.from(PushProperties(providerEnabled = true))
        }
        assertFailsWith<IllegalArgumentException> {
            PushRuntimeSettings.from(
                PushProperties(projectId = "INVALID PROJECT", credentialsFile = "/tmp/firebase.json"),
            )
        }
        assertFailsWith<IllegalArgumentException> {
            PushRuntimeSettings.from(PushProperties(dispatchEnabled = true))
        }
    }
}
