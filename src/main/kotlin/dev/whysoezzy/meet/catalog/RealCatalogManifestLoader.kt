package dev.whysoezzy.meet.catalog

import tools.jackson.databind.ObjectMapper
import tools.jackson.core.StreamReadFeature
import tools.jackson.databind.DeserializationFeature
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
    private val strictReader = objectMapper.reader(
        DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES,
        DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES,
        DeserializationFeature.FAIL_ON_MISSING_CREATOR_PROPERTIES,
        DeserializationFeature.FAIL_ON_NULL_CREATOR_PROPERTIES,
        DeserializationFeature.FAIL_ON_TRAILING_TOKENS,
    ).with(StreamReadFeature.STRICT_DUPLICATE_DETECTION)

    fun load(revisionLabel: String): RealCatalogLoadedManifest {
        require(revisionLabel.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$"))) { "Invalid catalog revision" }
        val resource = resourceLoader.getResource("classpath:real-catalog/$revisionLabel.json")
        require(resource.exists()) { "Real catalog revision not found" }
        val bytes = resource.inputStream.use { it.readNBytes(RealCatalogManifestValidator.MAX_BYTES + 1) }
        require(bytes.size <= RealCatalogManifestValidator.MAX_BYTES) { "Real catalog manifest is too large" }
        val manifest: RealCatalogManifest = strictReader.forType(RealCatalogManifest::class.java).readValue(bytes)
        val digest = validator.validate(manifest, bytes)
        return RealCatalogLoadedManifest(manifest, bytes, digest)
    }
}
