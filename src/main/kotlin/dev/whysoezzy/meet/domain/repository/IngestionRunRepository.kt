package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface IngestionRunRepository : JpaRepository<IngestionRun, Long> {
    fun findTop20BySourceOrderByStartedAtDesc(source: EventSource): List<IngestionRun>
}