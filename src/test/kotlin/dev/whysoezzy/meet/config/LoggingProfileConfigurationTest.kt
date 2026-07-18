package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import org.yaml.snakeyaml.Yaml
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertEquals

class LoggingProfileConfigurationTest {

    @Test
    fun `production uses INFO and dev explicitly enables DEBUG for application logs`() {
        assertEquals("INFO", loggingLevel("application.yml"))
        assertEquals("DEBUG", loggingLevel("application-dev.yml"))
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
}
