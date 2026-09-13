package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.config.PushProperties
import mu.KotlinLogging
import org.springframework.context.annotation.Conditional
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.time.Clock

private val logger = KotlinLogging.logger {}

@Component
@Conditional(DiscoveryPushCondition::class)
class MeetingReminderScheduler(
    private val properties: PushProperties,
    private val reminders: MeetingReminderStore,
    transactionManager: PlatformTransactionManager,
    private val clock: Clock,
) {
    private val transaction = TransactionTemplate(transactionManager).apply {
        timeout = 5
    }

    @Scheduled(fixedDelay = 60_000)
    fun discoverDueReminders() {
        if (!properties.providerEnabled || !properties.discoveryEnabled) return
        try {
            val now = clock.instant().truncatedTo(java.time.temporal.ChronoUnit.MILLIS)
            reminders.findCandidates(now, 100).forEach { candidate ->
                runCatching {
                    transaction.execute {
                        reminders.setLockTimeout()
                        reminders.discover(candidate, now)
                    }
                }.onFailure {
                    logger.warn { "Push reminder discovery failed" }
                }
            }
        } catch (_: Exception) {
            // Scheduled invocations must remain alive after a transient DB error.
            logger.warn { "Push reminder discovery unavailable" }
        }
    }
}

class DiscoveryPushCondition : org.springframework.context.annotation.Condition {
    override fun matches(
        context: org.springframework.context.annotation.ConditionContext,
        metadata: org.springframework.core.type.AnnotatedTypeMetadata,
    ): Boolean =
        context.environment.getProperty("app.push.provider-enabled", Boolean::class.java, false) &&
            context.environment.getProperty("app.push.discovery-enabled", Boolean::class.java, false)
}
