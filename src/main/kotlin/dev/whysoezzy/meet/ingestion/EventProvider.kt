package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import java.time.LocalDateTime

/**
 * Адаптер источника событий. Один реализующий бин = один источник.
 * Все бины EventProvider Spring автоматически соберёт в IngestionService.
 */
interface EventProvider {

    /** Какой источник обслуживает провайдер. */
    fun source(): EventSource

    /**
     * Достать события из источника.
     * @param since подтягивать созданные/обновлённые после этого момента (инкрементально); null — полная выборка.
     */
    fun fetch(since: LocalDateTime?): List<RawEvent>
}