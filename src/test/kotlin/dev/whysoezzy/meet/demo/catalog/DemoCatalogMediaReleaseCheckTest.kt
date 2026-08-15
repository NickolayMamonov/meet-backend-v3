package dev.whysoezzy.meet.demo.catalog

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.security.MessageDigest
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@EnabledIfEnvironmentVariable(named = "DEMO_CATALOG_MEDIA_PROBE", matches = "true")
class DemoCatalogMediaReleaseCheckTest {
    private val expected = mapOf(
        "${BetaDemoCatalog.MEDIA_BASE}community-moscow.png" to "4cae7410a1e0c9e28491631a59df89b10776ced8e5250d91d01157d2adc158ac",
        "${BetaDemoCatalog.MEDIA_BASE}community-walks.png" to "a4b90e77d01aa3387dfc72288d6565da8fa178730fac43441ac60262235c2ee6",
        "${BetaDemoCatalog.MEDIA_BASE}community-online.png" to "cd0c606d0242e688279b02301e7606132f4493cab83a6a55c7ed164dd0e8ee0d",
        "${BetaDemoCatalog.MEDIA_BASE}meeting-moscow.png" to "674bf6797c1227772bc19e1bca406de9853ca52112d3298cab9a67e84afb1439",
        "${BetaDemoCatalog.MEDIA_BASE}meeting-online.png" to "43378f9e7900f83a0ba86d9244f6f10f09d2f291ce8561f51ddbec5b132e8f46",
        "${BetaDemoCatalog.MEDIA_BASE}avatar-01.png" to "48b6c14991eddce94834bff01b7371d0de02c36ad136565e1a37d1171fc0cc40",
        "${BetaDemoCatalog.MEDIA_BASE}avatar-02.png" to "06ec16e4bcfd833a15bc16fa8416610769be8a6a444743159626d8317fd94cf8",
        "${BetaDemoCatalog.MEDIA_BASE}avatar-03.png" to "bfdd6f5ef6e3d5375d0c21cb7bc59a494f22f80628a35d5ae6c535f3ae5bd940",
        "${BetaDemoCatalog.MEDIA_BASE}avatar-04.png" to "1b4a000feaf4fc4bd173590bf8811e8142d74f968f319b2cfb7022d11aae05a6",
        "${BetaDemoCatalog.MEDIA_BASE}avatar-05.png" to "f820de837384b5068ca49147bfd7d228751445738d0f3f5e7bbafe8936f2a14b",
        "${BetaDemoCatalog.MEDIA_BASE}avatar-06.png" to "ad80b8b4c46e0d30860b872c5a4e8ba557954f66830d3b302eb265521c6fcca2",
        "https://api.whysoezzy.online/demo-events/organize-online" to "3229a94a4cc9698f5ed09320a80a68ec9b9746e5661a982b872d90157cba72b6",
        "https://api.whysoezzy.online/demo-events/networking-online" to "5c7baf9641ba6b602444595199dff14c0cca31125ca3f666f5fd63b9766e0900",
    )

    @Test
    fun `deployed host serves exact approved bodies`() {
        val client = HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NORMAL)
            .connectTimeout(java.time.Duration.ofSeconds(10))
            .build()
        expected.forEach { (url, digest) ->
            val response = client.send(
                HttpRequest.newBuilder(URI(url)).timeout(java.time.Duration.ofSeconds(20)).GET().build(),
                HttpResponse.BodyHandlers.ofByteArray(),
            )
            assertTrue(response.uri().scheme == "https" && response.uri().host == "api.whysoezzy.online")
            assertTrue(response.statusCode() in 200..299)
            val contentType = response.headers().firstValue("content-type").orElse("")
            if (url.endsWith(".png")) assertTrue(contentType.startsWith("image/png"))
            else assertTrue(contentType.startsWith("text/html"))
            assertEquals(digest, sha256(response.body()), url)
        }
    }

    private fun sha256(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
