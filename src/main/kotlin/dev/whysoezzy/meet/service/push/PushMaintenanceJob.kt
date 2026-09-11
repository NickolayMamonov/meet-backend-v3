package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.config.PushRuntimeSettings
import mu.KotlinLogging
import org.springframework.context.annotation.Conditional
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.time.Clock

private val maintenanceLogger = KotlinLogging.logger {}

@Component
@Conditional(MaintenancePushCondition::class)
class PushMaintenanceJob(
    private val store: ReminderDispatchStore,
    private val installations: PushInstallationStore,
    transactionManager: PlatformTransactionManager,
    private val clock: Clock,
) {
    private val transaction = TransactionTemplate(transactionManager).apply {
        timeout = TRANSACTION_TIMEOUT_SECONDS
    }

    @Scheduled(fixedDelay = PushRuntimeSettings.MAINTENANCE_INTERVAL_SECONDS * 1_000)
    fun run() {
        try {
            transaction.execute {
                installations.expireStale(clock.instant(), PushRuntimeSettings.PASS_LIMIT)
                store.recoverAndExpire(PushRuntimeSettings.PASS_LIMIT, clock.instant())
            }
        } catch (exception: Exception) {
            // Keep scheduling alive and keep the log free of SQL/credential
            // content. The next pass will retry the bounded candidate set.
            maintenanceLogger.warn {
                "push maintenance failure category=${exception::class.simpleName}"
            }
        }
    }

    private companion object {
        const val TRANSACTION_TIMEOUT_SECONDS = 5
    }
}
