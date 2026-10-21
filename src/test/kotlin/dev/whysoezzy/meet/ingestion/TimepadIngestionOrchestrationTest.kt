package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import dev.whysoezzy.meet.domain.entity.IngestionStatus
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import org.junit.jupiter.api.Test
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoInteractions
import org.mockito.Mockito.`when`
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TimepadIngestionOrchestrationTest {
    @Test
    fun `incomplete provider observation never invokes catalog apply`() {
        val provider = ControlledProvider { ProviderFetchResult.Incomplete("missing_saved_id") }
        val (service, apply, upsert) = service(provider)

        val result = service.runProvider(provider)

        assertEquals(IngestionStatus.FAILED, result.status)
        assertEquals("Timepad snapshot incomplete: missing_saved_id", result.errorMessage)
        assertEquals(1, provider.calls.get())
        verifyNoInteractions(apply, upsert)
    }

    @Test
    fun `overlapping run reports partial without second provider call or catalog write`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val provider = ControlledProvider {
            entered.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
            ProviderFetchResult.Incomplete("synthetic_incomplete")
        }
        val (service, apply, upsert) = service(provider)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val first = executor.submit<IngestionRun> { service.runProvider(provider) }
            assertTrue(entered.await(5, TimeUnit.SECONDS))

            val overlap = service.runProvider(provider)

            assertEquals(IngestionStatus.PARTIAL, overlap.status)
            assertEquals("concurrent_run", overlap.errorMessage)
            assertEquals(1, provider.calls.get())
            release.countDown()
            assertEquals(IngestionStatus.FAILED, first.get(5, TimeUnit.SECONDS).status)
            verifyNoInteractions(apply, upsert)
        } finally {
            release.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    private fun service(provider: EventProvider): Triple<IngestionService, TimepadCatalogApplyService, MeetingUpsertService> {
        val meetingRepository = mock(MeetingRepository::class.java)
        `when`(
            meetingRepository.findTop501BySourceAndSourceExternalIdNotNullOrderByIdAsc(EventSource.TIMEPAD),
        ).thenReturn(emptyList())
        val runRepository = mock(IngestionRunRepository::class.java)
        doAnswer { it.getArgument<IngestionRun>(0) }
            .`when`(runRepository)
            .save(org.mockito.ArgumentMatchers.any(IngestionRun::class.java) ?: IngestionRun(EventSource.TIMEPAD))
        val apply = mock(TimepadCatalogApplyService::class.java)
        val upsert = mock(MeetingUpsertService::class.java)
        val service = IngestionService(
            mock(org.springframework.beans.factory.ObjectProvider::class.java) as org.springframework.beans.factory.ObjectProvider<EventProvider>,
            upsert,
            apply,
            runRepository,
            meetingRepository,
            Clock.fixed(Instant.parse("2026-10-21T10:00:00Z"), ZoneOffset.UTC),
        )
        return Triple(service, apply, upsert)
    }

    private class ControlledProvider(
        private val response: () -> ProviderFetchResult,
    ) : EventProvider {
        val calls = AtomicInteger()

        override fun source() = EventSource.TIMEPAD

        override fun fetch(context: FetchContext): ProviderFetchResult {
            calls.incrementAndGet()
            return response()
        }
    }
}
