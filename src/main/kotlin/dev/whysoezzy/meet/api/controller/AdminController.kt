package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.IngestRunSummary
import dev.whysoezzy.meet.api.dto.IngestTriggerResponse
import dev.whysoezzy.meet.ingestion.IngestionService
import org.springframework.beans.factory.annotation.Value
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/admin")
class AdminController(
    private val ingestionService: IngestionService,
    @Value("\${app.admin.api-key:}") private val adminApiKey: String,
) {
    @PostMapping("/ingest")
    fun triggerIngest(
        @RequestHeader(value = "X-Admin-Key", required = false) apiKey: String?,
    ): ResponseEntity<IngestTriggerResponse> {
        // Пустой ключ → эндпоинт выключен (всегда 403), пока не задан ADMIN_API_KEY
        if (adminApiKey.isBlank() || apiKey != adminApiKey) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build()
        }
        val summary = ingestionService.runAll().map {
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
        return ResponseEntity.ok(IngestTriggerResponse(runs = summary))
    }

    @DeleteMapping("/purge")
    fun purge(
        @RequestHeader(value = "X-Admin-Key", required = false) apiKey: String?,
        @RequestParam source: String,
    ): ResponseEntity<Map<String, Any>> {
        if (adminApiKey.isBlank() || apiKey != adminApiKey) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build()
        }
        val src = dev.whysoezzy.meet.domain.entity.EventSource.valueOf(source.uppercase())
        val deleted = ingestionService.purgeBySource(src)
        return ResponseEntity.ok(mapOf("source" to src.name, "deleted" to deleted))
    }
}