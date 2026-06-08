package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.stereotype.Component

@Component
@ConfigurationProperties(prefix = "app.timepad")
class TimepadProperties {
    var enabled: Boolean = false
    var baseUrl: String = "https://api.timepad.ru/v1"
    var token: String = ""                  // опциональный Bearer; пусто = публичный доступ
    var categoryIds: List<Int> = emptyList() // пусто = все категории
    var keywords: List<String> = emptyList() // слова в названии события
    var cities: List<String> = emptyList()
    var pageSize: Int = 100                  // 1..100
    var maxPages: Int = 5                    // ограничение (rate limit 60 req/min)
    var daysAhead: Long = 180                // окно starts_at_min..max
    var zone: String = "Europe/Moscow"       // для дат без таймзоны
}