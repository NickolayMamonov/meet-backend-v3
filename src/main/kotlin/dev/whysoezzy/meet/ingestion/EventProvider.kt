package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import java.time.Instant

/**
 * Адаптер источника событий. Один реализующий бин = один источник.
 * Все бины EventProvider Spring автоматически соберёт в IngestionService.
 */
interface EventProvider {

    /** Какой источник обслуживает провайдер. */
    fun source(): EventSource

    fun fetch(context: FetchContext): ProviderFetchResult
}

data class FetchContext(
    val observedAt: Instant,
    val savedExternalIds: List<String>,
)

sealed interface ProviderFetchResult {
    data class Complete(
        val accepted: List<RawEvent>,
        val rejectedSavedExternalIds: Set<String>,
        val observedCount: Int,
    ) : ProviderFetchResult

    data class Incomplete(val reason: String) : ProviderFetchResult
}
