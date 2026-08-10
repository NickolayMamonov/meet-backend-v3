package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import dev.whysoezzy.meet.domain.entity.IngestionStatus
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import mu.KotlinLogging
import org.springframework.beans.factory.ObjectProvider
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

private val logger = KotlinLogging.logger {}

@Service
class IngestionService(
    private val providers: ObjectProvider<EventProvider>,
    private val upsertService: MeetingUpsertService,
    private val ingestionRunRepository: IngestionRunRepository,
    private val meetingRepository: MeetingRepository,
) {
    /** Прогнать все зарегистрированные источники. */
    fun runAll(): List<IngestionRun> = providers.toList().map { runProvider(it) }



    /** Прогон одного источника: изоляция ошибок + запись в журнал. */
    fun runProvider(provider: EventProvider): IngestionRun {
        val run = IngestionRun(source = provider.source(), status = IngestionStatus.RUNNING)
        ingestionRunRepository.save(run)

        var hadEventError = false
        try {
            val events = provider.fetch(null) // since=null → полная выборка; инкрементальность в W7
            run.fetchedCount = events.size
            for (raw in events) {
                try {
                    when (upsertService.upsert(provider.source(), raw)) {
                        UpsertResult.CREATED -> run.createdCount++
                        UpsertResult.UPDATED -> run.updatedCount++
                        UpsertResult.SKIPPED -> run.skippedCount++
                    }
                } catch (_: Exception) {
                    hadEventError = true
                    run.skippedCount++
                    logger.warn { "Ingestion event skipped: source=${provider.source()}" }
                }
            }
            run.status = if (hadEventError) IngestionStatus.PARTIAL else IngestionStatus.SUCCESS
        } catch (_: Exception) {
            run.status = IngestionStatus.FAILED
            run.errorMessage = "Provider fetch failed"
            logger.error { "Ingestion provider failed: source=${provider.source()}" }
        } finally {
            run.finishedAt = LocalDateTime.now()
            ingestionRunRepository.save(run)
        }
        return run
    }

    @Transactional
    fun purgeBySource(source: EventSource): Int =
        meetingRepository.deleteBySource(source)

}
