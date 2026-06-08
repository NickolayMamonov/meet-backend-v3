package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "ingestion_runs")
class IngestionRun(

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    var source: EventSource,

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    var status: IngestionStatus = IngestionStatus.RUNNING,

    @Column(name = "fetched_count", nullable = false)
    var fetchedCount: Int = 0,

    @Column(name = "created_count", nullable = false)
    var createdCount: Int = 0,

    @Column(name = "updated_count", nullable = false)
    var updatedCount: Int = 0,

    @Column(name = "skipped_count", nullable = false)
    var skippedCount: Int = 0,

    @Column(name = "error_message", columnDefinition = "TEXT")
    var errorMessage: String? = null,

    @Column(name = "started_at", nullable = false)
    var startedAt: LocalDateTime = LocalDateTime.now(),

    @Column(name = "finished_at")
    var finishedAt: LocalDateTime? = null,

    ) : BaseEntity()

enum class IngestionStatus {
    RUNNING,   // прогон стартовал
    SUCCESS,   // все события обработаны без ошибок
    PARTIAL,   // часть обработана, были ошибки на отдельных событиях
    FAILED     // источник недоступен / прогон упал целиком
}