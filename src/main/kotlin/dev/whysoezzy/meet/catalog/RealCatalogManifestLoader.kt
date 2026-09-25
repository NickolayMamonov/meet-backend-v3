package dev.whysoezzy.meet.catalog

import tools.jackson.databind.ObjectMapper
import org.springframework.core.io.ResourceLoader
import org.springframework.stereotype.Component

data class RealCatalogLoadedManifest(
    val manifest: RealCatalogManifest,
    val bytes: ByteArray,
    val digest: String,
)

@Component
class RealCatalogManifestLoader(
    private val resourceLoader: ResourceLoader,
    private val objectMapper: ObjectMapper,
    private val validator: RealCatalogManifestValidator,
) {
    fun load(revisionLabel: String): RealCatalogLoadedManifest {
        require(revisionLabel.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$"))) { "Invalid catalog revision" }
        val resource = resourceLoader.getResource("classpath:real-catalog/$revisionLabel.json")
        require(resource.exists()) { "Real catalog revision not found" }
        val bytes = resource.inputStream.use { it.readBytes() }
        val manifest = objectMapper.readValue(bytes, RealCatalogManifest::class.java)
        val digest = validator.validate(manifest, bytes)
        return RealCatalogLoadedManifest(manifest, bytes, digest)
    }
}
