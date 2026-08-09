package dev.whysoezzy.meet.ingestion

import mu.KotlinLogging
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

private val logger = KotlinLogging.logger {}

@Component
@ConditionalOnProperty(prefix = "app.ingestion", name = ["enabled"], havingValue = "true", matchIfMissing = true)
class IngestionScheduler(
    private val ingestionService: IngestionService,
) {
    @Scheduled(cron = "\${app.ingestion.cron}", zone = "\${app.ingestion.zone}")
    fun scheduled() {
        logger.info { "Запуск ингестии по расписанию" }
        val runs = ingestionService.runAll()
        logger.info { "Ингестия завершена: прогонов=${runs.size}" }
    }
}
