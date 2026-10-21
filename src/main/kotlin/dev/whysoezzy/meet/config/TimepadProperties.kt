package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.stereotype.Component
import jakarta.annotation.PostConstruct
import java.net.URI

@Component
@ConfigurationProperties(prefix = "app.timepad")
class TimepadProperties {
    var enabled: Boolean = false
    var baseUrl: String = "https://api.timepad.ru/v1"
    var token: String = ""                  // опциональный Bearer; пусто = публичный доступ
    var assetBaseUrl: String = ""
    var pageSize: Int = 100                  // 1..100
    var maxPages: Int = 5                    // ограничение (rate limit 60 req/min)
    var zone: String = "Europe/Moscow"       // для дат без таймзоны

    @PostConstruct
    fun validate() {
        if (!enabled) return
        val apiBase = runCatching { URI(baseUrl) }.getOrNull()
        require(
            apiBase?.scheme == "https" &&
                apiBase.host.equals("api.timepad.ru", ignoreCase = true) &&
                apiBase.path.trimEnd('/') == "/v1" &&
                apiBase.rawUserInfo == null && apiBase.rawQuery == null &&
                apiBase.rawFragment == null && apiBase.port in setOf(-1, 443),
        ) { "app.timepad.base-url must be https://api.timepad.ru/v1 when Timepad is enabled" }
        val assetBase = runCatching { URI(assetBaseUrl) }.getOrNull()
        require(
            assetBase != null && assetBase.scheme == "https" &&
                !assetBase.host.isNullOrBlank() && assetBase.rawUserInfo == null &&
                assetBase.rawQuery == null && assetBase.rawFragment == null,
        ) { "app.timepad.asset-base-url must be an HTTPS URL when Timepad is enabled" }
        require(zone == "Europe/Moscow") { "app.timepad.zone must be Europe/Moscow" }
        require(pageSize == 100 && maxPages in 1..5) {
            "app.timepad pagination bounds are invalid"
        }
    }
}
