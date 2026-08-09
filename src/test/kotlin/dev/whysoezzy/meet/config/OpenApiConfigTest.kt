package dev.whysoezzy.meet.config

import org.springframework.boot.info.BuildProperties
import java.util.Properties
import kotlin.test.Test
import kotlin.test.assertEquals

class OpenApiConfigTest {

    @Test
    fun `OpenAPI version comes from packaged build metadata`() {
        val properties = Properties().apply { setProperty("version", "1.0.0") }

        val openApi = OpenApiConfig(BuildProperties(properties)).openAPI()

        assertEquals("1.0.0", openApi.info.version)
    }
}
