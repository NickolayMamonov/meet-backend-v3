package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import org.yaml.snakeyaml.Yaml
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LoggingProfileConfigurationTest {

    @Test
    fun `production uses INFO and dev explicitly enables DEBUG for application logs`() {
        assertEquals("INFO", loggingLevel("application.yml"))
        assertEquals("DEBUG", loggingLevel("application-dev.yml"))
    }

    @Test
    fun `production suppresses resolved MVC exception logs while dev explicitly enables them`() {
        assertFalse(logResolvedException("application.yml"))
        assertTrue(logResolvedException("application-dev.yml"))
    }

    @Suppress("UNCHECKED_CAST")
    private fun loggingLevel(resource: String): String {
        val yaml = Files.newBufferedReader(Path.of("src/main/resources").resolve(resource)).use {
            Yaml().load<Map<String, Any>>(it)
        }
        val logging = yaml.getValue("logging") as Map<String, Any>
        val level = logging.getValue("level") as Map<String, String>
        return level.getValue("dev.whysoezzy")
    }

    @Suppress("UNCHECKED_CAST")
    private fun logResolvedException(resource: String): Boolean {
        val yaml = Files.newBufferedReader(Path.of("src/main/resources").resolve(resource)).use {
            Yaml().load<Map<String, Any>>(it)
        }
        val spring = yaml.getValue("spring") as Map<String, Any>
        val mvc = spring.getValue("mvc") as Map<String, Any>
        return mvc.getValue("log-resolved-exception") as Boolean
    }
}
