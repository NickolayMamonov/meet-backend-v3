package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.config.PushRuntimeSettings
import mu.KotlinLogging
import org.springframework.context.SmartLifecycle
import org.springframework.context.annotation.Conditional
import org.springframework.stereotype.Component
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

private val workerLogger = KotlinLogging.logger {}

/**
 * Four fixed, sequential workers. Each scheduled task can have only one
 * in-flight dispatch call, so a slow synchronous SDK call occupies its slot
 * until it returns. There is no per-target future queue to grow without bound.
 */
@Component
@Conditional(DispatchPushCondition::class)
class PushWorkerLifecycle(
    private val dispatcher: ReminderDispatcher,
) : SmartLifecycle {
    private val accepting = AtomicBoolean(false)
    private var executor: ScheduledExecutorService? = null

    override fun start() {
        if (!accepting.compareAndSet(false, true)) return
        val created = Executors.newScheduledThreadPool(
            PushRuntimeSettings.DISPATCH_WORKERS,
            NamedWorkerFactory(),
        )
        executor = created
        repeat(PushRuntimeSettings.DISPATCH_WORKERS) {
            created.scheduleWithFixedDelay(
                {
                    if (!accepting.get()) return@scheduleWithFixedDelay
                    try {
                        dispatcher.dispatchOne()
                    } catch (exception: Exception) {
                        // A thrown task must not cancel a periodic worker.
                        workerLogger.warn {
                            "push worker failure category=${exception::class.simpleName}"
                        }
                    }
                },
                0,
                PushRuntimeSettings.IDLE_DISPATCH_DELAY_SECONDS,
                TimeUnit.SECONDS,
            )
        }
    }

    override fun stop() {
        stop {}
    }

    override fun stop(callback: Runnable) {
        if (!accepting.compareAndSet(true, false)) {
            callback.run()
            return
        }
        val running = executor
        executor = null
        running?.shutdown()
        try {
            if (running == null || running.awaitTermination(SHUTDOWN_GRACE_SECONDS, TimeUnit.SECONDS)) {
                callback.run()
            } else {
                // In-flight leases remain durable and are recovered by the
                // maintenance pass. Do not submit replacement work here.
                running.shutdownNow()
                callback.run()
            }
        } catch (exception: InterruptedException) {
            Thread.currentThread().interrupt()
            running?.shutdownNow()
            callback.run()
        }
    }

    override fun isRunning(): Boolean = accepting.get()
    override fun isAutoStartup(): Boolean = true
    override fun getPhase(): Int = Int.MAX_VALUE - 100

    private class NamedWorkerFactory : ThreadFactory {
        private val sequence = AtomicInteger()

        override fun newThread(runnable: Runnable): Thread =
            Thread(runnable, "push-dispatch-${sequence.incrementAndGet()}").apply {
                isDaemon = false
            }
    }

    private companion object {
        const val SHUTDOWN_GRACE_SECONDS = 20L
    }
}
