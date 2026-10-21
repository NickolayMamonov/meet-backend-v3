package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import dev.whysoezzy.meet.domain.entity.IngestionStatus
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Propagation
import org.springframework.transaction.annotation.Transactional
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.LocalDateTime

@Service
class TimepadCatalogApplyService(
    private val upsertService: MeetingUpsertService,
    private val meetingRepository: MeetingRepository,
    private val ingestionRunRepository: IngestionRunRepository,
    private val jdbc: JdbcTemplate,
    private val clock: Clock,
) {
    @Transactional(timeout = 15)
    fun apply(
        run: IngestionRun,
        observedAt: Instant,
        snapshot: ProviderFetchResult.Complete,
    ): IngestionRun {
        jdbc.execute("SET LOCAL lock_timeout = '1s'")
        jdbc.execute("SET LOCAL statement_timeout = '5s'")
        val eligibleUntil = observedAt.plus(Duration.ofHours(72)).toEpochMilli()
        run.fetchedCount = snapshot.observedCount
        snapshot.accepted.forEach { event ->
            when (upsertService.upsertTimepad(event, eligibleUntil)) {
                UpsertResult.CREATED -> run.createdCount++
                UpsertResult.UPDATED -> run.updatedCount++
                UpsertResult.SKIPPED -> run.skippedCount++
            }
        }
        if (snapshot.rejectedSavedExternalIds.isNotEmpty()) {
            meetingRepository.findAllBySourceAndSourceExternalIdIn(
                EventSource.TIMEPAD,
                snapshot.rejectedSavedExternalIds,
            ).forEach { it.timepadEligibleUntilMs = null }
        }
        run.skippedCount += snapshot.observedCount - snapshot.accepted.size
        run.status = IngestionStatus.SUCCESS
        run.errorMessage = null
        run.finishedAt = LocalDateTime.now(clock)
        return ingestionRunRepository.save(run)
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    fun reconcileApplyFailure(runId: Long, reason: String): IngestionRun {
        val run = ingestionRunRepository.findById(runId).orElseThrow {
            IllegalStateException("Timepad ingestion run disappeared during apply reconciliation")
        }
        if (run.status != IngestionStatus.RUNNING) return run

        run.fetchedCount = 0
        run.createdCount = 0
        run.updatedCount = 0
        run.skippedCount = 0
        run.status = IngestionStatus.FAILED
        run.errorMessage = "Timepad apply failed: $reason"
        run.finishedAt = LocalDateTime.now(clock)
        return ingestionRunRepository.save(run)
    }
}
