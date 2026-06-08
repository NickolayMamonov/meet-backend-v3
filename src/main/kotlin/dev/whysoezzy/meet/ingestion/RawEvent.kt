package dev.whysoezzy.meet.ingestion

/**
 * Нормализованное событие из любого источника — до маппинга в сущность Meeting.
 * Провайдер заполняет все поля; пустые подставляет сам (см. комментарии).
 */
data class RawEvent(
    val sourceExternalId: String,   // id события на площадке (для дедупликации/upsert)
    val title: String,
    val description: String,
    val imageUrl: String,           // "" если у источника нет картинки
    val startsAtEpochMs: Long,      // время начала, Unix ms → Meeting.time
    val address: String,            // "Онлайн" для онлайн-событий
    val latitude: Double,           // 0.0 если координат нет / онлайн
    val longitude: Double,          // 0.0 если координат нет / онлайн
    val externalUrl: String?,       // ссылка на страницу события на площадке
    val isOnline: Boolean,
    val topicKeywords: Set<String> = emptySet(), // категории источника → тегирование в W3
)