package dev.whysoezzy.meet.demo.catalog

import org.junit.jupiter.api.Test
import java.security.MessageDigest
import kotlin.test.assertEquals

class DemoCatalogPublicAssetsTest {
    private val digests = mapOf(
        "static/demo-assets/v1/community-moscow.png" to Triple(1200, 675, "4cae7410a1e0c9e28491631a59df89b10776ced8e5250d91d01157d2adc158ac"),
        "static/demo-assets/v1/community-walks.png" to Triple(1200, 675, "a4b90e77d01aa3387dfc72288d6565da8fa178730fac43441ac60262235c2ee6"),
        "static/demo-assets/v1/community-online.png" to Triple(1200, 675, "cd0c606d0242e688279b02301e7606132f4493cab83a6a55c7ed164dd0e8ee0d"),
        "static/demo-assets/v1/meeting-moscow.png" to Triple(1200, 675, "674bf6797c1227772bc19e1bca406de9853ca52112d3298cab9a67e84afb1439"),
        "static/demo-assets/v1/meeting-online.png" to Triple(1200, 675, "43378f9e7900f83a0ba86d9244f6f10f09d2f291ce8561f51ddbec5b132e8f46"),
        "static/demo-assets/v1/avatar-01.png" to Triple(512, 512, "48b6c14991eddce94834bff01b7371d0de02c36ad136565e1a37d1171fc0cc40"),
        "static/demo-assets/v1/avatar-02.png" to Triple(512, 512, "06ec16e4bcfd833a15bc16fa8416610769be8a6a444743159626d8317fd94cf8"),
        "static/demo-assets/v1/avatar-03.png" to Triple(512, 512, "bfdd6f5ef6e3d5375d0c21cb7bc59a494f22f80628a35d5ae6c535f3ae5bd940"),
        "static/demo-assets/v1/avatar-04.png" to Triple(512, 512, "1b4a000feaf4fc4bd173590bf8811e8142d74f968f319b2cfb7022d11aae05a6"),
        "static/demo-assets/v1/avatar-05.png" to Triple(512, 512, "f820de837384b5068ca49147bfd7d228751445738d0f3f5e7bbafe8936f2a14b"),
        "static/demo-assets/v1/avatar-06.png" to Triple(512, 512, "ad80b8b4c46e0d30860b872c5a4e8ba557954f66830d3b302eb265521c6fcca2"),
    )

    @Test
    fun `all PNG bytes, dimensions and digests are frozen`() {
        digests.forEach { (path, expected) ->
            val bytes = requireNotNull(javaClass.classLoader.getResourceAsStream(path)).readBytes()
            assertEquals(expected.third, sha256(bytes), path)
            assertEquals(expected.first, bytes.readInt(16), path)
            assertEquals(expected.second, bytes.readInt(20), path)
        }
    }

    @Test
    fun `landing page bytes are frozen`() {
        assertHtml("static/demo-events/organize-online", 911, "3229a94a4cc9698f5ed09320a80a68ec9b9746e5661a982b872d90157cba72b6")
        assertHtml("static/demo-events/networking-online", 870, "5c7baf9641ba6b602444595199dff14c0cca31125ca3f666f5fd63b9766e0900")
    }

    private fun assertHtml(path: String, length: Int, digest: String) {
        val bytes = requireNotNull(javaClass.classLoader.getResourceAsStream(path)).readBytes()
        assertEquals(length, bytes.size, path)
        assertEquals(digest, sha256(bytes), path)
    }

    private fun sha256(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun ByteArray.readInt(offset: Int) =
        (this[offset].toInt() and 0xff) shl 24 or
            ((this[offset + 1].toInt() and 0xff) shl 16) or
            ((this[offset + 2].toInt() and 0xff) shl 8) or
            (this[offset + 3].toInt() and 0xff)
}
