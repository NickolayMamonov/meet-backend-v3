package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import dev.whysoezzy.meet.domain.entity.IngestionStatus
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import mu.KotlinLogging
import org.springframework.beans.factory.ObjectProvider
import org.springframework.stereotype.Service
import java.time.Clock
import java.time.Instant
import java.time.LocalDateTime
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private val logger = KotlinLogging.logger {}

@Service
class IngestionService(
    private val providers: ObjectProvider<EventProvider>,
    private val upsertService: MeetingUpsertService,
    private val timepadApplyService: TimepadCatalogApplyService,
    private val ingestionRunRepository: IngestionRunRepository,
    private val meetingRepository: MeetingRepository,
    private val clock: Clock,
) {
    /** Прогнать все зарегистрированные источники. */
    fun runAll(): List<IngestionRun> = providers.toList().map { runProvider(it) }

    /** Прогон одного источника: изоляция ошибок + запись в журнал. */
    fun runProvider(provider: EventProvider): IngestionRun {
        if (provider.source() == EventSource.TIMEPAD) return runTimepad(provider)
        val run = IngestionRun(source = provider.source(), status = IngestionStatus.RUNNING)
        ingestionRunRepository.save(run)

        try {
            when (val fetched = provider.fetch(FetchContext(clock.instant(), emptyList()))) {
                is ProviderFetchResult.Incomplete -> {
                    run.status = IngestionStatus.FAILED
                    run.errorMessage = "Provider snapshot incomplete: ${fetched.reason}"
                }
                is ProviderFetchResult.Complete -> {
                    run.fetchedCount = fetched.observedCount
                    fetched.accepted.forEach { event ->
                        when (upsertService.upsert(provider.source(), event)) {
                            UpsertResult.CREATED -> run.createdCount++
                            UpsertResult.UPDATED -> run.updatedCount++
                            UpsertResult.SKIPPED -> run.skippedCount++
                        }
                    }
                    run.status = IngestionStatus.SUCCESS
                }
            }
        } catch (_: Exception) {
            run.status = IngestionStatus.FAILED
            run.errorMessage = "Provider snapshot failed"
            logger.error { "Ingestion provider failed: source=${provider.source()} reason=provider_failure" }
        } finally {
            run.finishedAt = LocalDateTime.now(clock)
            ingestionRunRepository.save(run)
        }
        return run
    }

    private fun runTimepad(provider: EventProvider): IngestionRun {
        val run = IngestionRun(source = EventSource.TIMEPAD, status = IngestionStatus.RUNNING)
        if (!timepadAdmission.tryLock()) {
            run.status = IngestionStatus.PARTIAL
            run.errorMessage = "concurrent_run"
            run.finishedAt = LocalDateTime.now(clock)
            return ingestionRunRepository.save(run)
        }
        try {
            val (observedAt, fetched) = try {
                val observedAt = clock.instant()
                val saved = meetingRepository.findTop501BySourceAndSourceExternalIdNotNullOrderByIdAsc(
                    EventSource.TIMEPAD,
                )
                if (saved.size > MAX_SAVED_IDS) {
                    return finishIncomplete(run, "saved_id_budget")
                }
                ingestionRunRepository.save(run)
                val context = FetchContext(observedAt, saved.mapNotNull { it.sourceExternalId }.toList())
                observedAt to provider.fetch(context)
            } catch (_: Exception) {
                logger.error { "Ingestion provider failed: source=TIMEPAD reason=provider_failure" }
                return finishIncomplete(run, "provider_failure")
            }
            return when (fetched) {
                is ProviderFetchResult.Incomplete -> finishIncomplete(run, fetched.reason)
                is ProviderFetchResult.Complete -> {
                    try {
                        timepadApplyService.apply(run, observedAt, fetched)
                    } catch (_: Exception) {
                        timepadApplyService.reconcileApplyFailure(
                            run.id ?: throw IllegalStateException("Timepad ingestion run was not persisted"),
                            "apply_failed",
                        )
                    }
                }
            }
        } finally {
            timepadAdmission.unlock()
        }
    }

    private fun finishIncomplete(run: IngestionRun, reason: String): IngestionRun {
        run.fetchedCount = 0
        run.createdCount = 0
        run.updatedCount = 0
        run.skippedCount = 0
        run.status = IngestionStatus.FAILED
        run.errorMessage = "Timepad snapshot incomplete: $reason"
        run.finishedAt = LocalDateTime.now(clock)
        return ingestionRunRepository.save(run)
    }

    fun purgeBySource(source: EventSource): Int =
        if (source == EventSource.TIMEPAD) {
            throw dev.whysoezzy.meet.api.error.ConflictException("Timepad catalog purge is disabled")
        } else {
            meetingRepository.deleteBySource(source)
        }

    private companion object {
        val timepadAdmission = ReentrantLock()
        const val MAX_SAVED_IDS = 500
    }

}
