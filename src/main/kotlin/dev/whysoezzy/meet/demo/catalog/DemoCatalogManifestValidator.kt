package dev.whysoezzy.meet.demo.catalog

import dev.whysoezzy.meet.domain.entity.AdBlockType
import java.net.URI
import org.springframework.stereotype.Component

@Component
class DemoCatalogManifestValidator {
    fun validate(manifest: BetaDemoCatalogManifest, allowedMediaHosts: Set<String>) {
        require(manifest.catalogName.isNotBlank() && manifest.manifestVersion.isNotBlank()) { "Invalid demo catalog manifest" }
        val keys = mutableSetOf<CatalogKey>()
        fun addKey(key: CatalogKey) {
            if (!keys.add(key)) throw IllegalArgumentException("Invalid demo catalog manifest")
        }
        manifest.tags.forEach { addKey(it.key); require(it.text.isNotBlank() && it.text.length <= 100) }
        manifest.users.forEach {
            addKey(it.key)
            require(it.name.isNotBlank() && it.surname.isNotBlank() && it.email.endsWith("@example.invalid"))
            require(it.interests.size == 2 && it.avatarUrl.startsWith("https://"))
            validateHttps(it.avatarUrl, allowedMediaHosts)
        }
        manifest.communities.forEach {
            addKey(it.key)
            require(it.name.isNotBlank() && it.description.isNotBlank())
            validateHttps(it.imageUrl, allowedMediaHosts)
        }
        manifest.meetings.forEach {
            addKey(it.key)
            require(it.title.isNotBlank() && it.description.isNotBlank() && it.durationMinutes > 0 && it.capacity > 0)
            require(it.latitude in -90.0..90.0 && it.longitude in -180.0..180.0)
            require(it.source.name == "MANUAL" && it.externalUrl?.startsWith("https://") != false)
            validateHttps(it.imageUrl, allowedMediaHosts)
            it.externalUrl?.let { url ->
                validateHttps(url, allowedMediaHosts)
                require(url in manifest.publicLandingUrls)
            }
        }
        manifest.adBlocks.forEach {
            addKey(it.key)
            require(it.type in AdBlockType.entries && it.title.isNotBlank() && it.description.isNotBlank())
            if (it.type == AdBlockType.TEXT) require(it.actionText == "Выбрать интересы" && it.actionUrl == "/profile/interests")
            else require(it.actionText == null && it.actionUrl == null)
        }
        val declared = keys.toSet()
        fun references(keysToCheck: Collection<CatalogKey>) = require(keysToCheck.all { it in declared })
        manifest.users.forEach { references(it.interests) }
        manifest.communities.forEach { references(it.tags + it.subscribers) }
        manifest.meetings.forEach { references(it.tags + it.participants + setOf(it.personHost, it.communityHost)) }
        manifest.adBlocks.forEach { references(it.communities + it.users) }
        require(manifest.users.map { it.email.lowercase() }.distinct().size == manifest.users.size)
    }

    private fun validateHttps(value: String, allowedMediaHosts: Set<String>) {
        val uri = runCatching { URI(value) }.getOrNull() ?: throw IllegalArgumentException("Invalid demo catalog manifest")
        require(uri.scheme == "https" && uri.userInfo == null && uri.fragment == null && uri.query == null)
        require(uri.host != null && uri.host.lowercase() in allowedMediaHosts.map { it.lowercase() })
        require(uri.path.startsWith("/") && uri.path.length > 1)
    }
}
