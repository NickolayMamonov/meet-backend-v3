package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.IngestRunSummary
import dev.whysoezzy.meet.api.dto.IngestTriggerResponse
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.ingestion.IngestionService
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/admin")
class AdminController(
    private val ingestionService: IngestionService,
) {
    @PostMapping("/ingest")
    fun triggerIngest(): ResponseEntity<IngestTriggerResponse> {
        val runs = ingestionService.runAll()
        val purgedPast = ingestionService.purgePastEvents()
        val summary = runs.map {
            IngestRunSummary(
                source = it.source.name,
                status = it.status.name,
                fetched = it.fetchedCount,
                created = it.createdCount,
                updated = it.updatedCount,
                skipped = it.skippedCount,
                errorMessage = it.errorMessage,
            )
        }
        return ResponseEntity.ok(IngestTriggerResponse(runs = summary, purgedPast = purgedPast))
    }

    @DeleteMapping("/purge")
    fun purge(
        @RequestParam source: String,
    ): ResponseEntity<Map<String, Any>> {
        val src = EventSource.entries.firstOrNull { it.name.equals(source, ignoreCase = true) }
            ?: throw BadRequestException("Invalid source")
        val deleted = ingestionService.purgeBySource(src)
        return ResponseEntity.ok(mapOf("source" to src.name, "deleted" to deleted))
    }
}
