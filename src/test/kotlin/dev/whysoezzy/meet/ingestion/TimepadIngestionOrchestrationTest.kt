package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import dev.whysoezzy.meet.domain.entity.IngestionStatus
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import org.junit.jupiter.api.Test
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.doThrow
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.times
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoInteractions
import org.mockito.Mockito.`when`
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.isNull
import org.springframework.transaction.support.TransactionSynchronizationManager
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFalse

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
    fun `truncated discovery result never invokes catalog apply`() {
        val provider = ControlledProvider { ProviderFetchResult.Incomplete("short_page") }
        val (service, apply, upsert) = service(provider)

        val result = service.runProvider(provider)

        assertEquals(IngestionStatus.FAILED, result.status)
        assertEquals("Timepad snapshot incomplete: short_page", result.errorMessage)
        verifyNoInteractions(apply, upsert)
    }

    @Test
    fun `apply acknowledgement loss reconciles durable success without stale failure save`() {
        val provider = ControlledProvider {
            ProviderFetchResult.Complete(emptyList(), emptySet(), observedCount = 0)
        }
        val runs = mock(IngestionRunRepository::class.java)
        val (service, apply, _) = service(provider, runs)
        val durableSuccess = IngestionRun(EventSource.TIMEPAD, IngestionStatus.SUCCESS).also { it.id = 1L }
        doThrow(IllegalStateException("simulated commit acknowledgement loss"))
            .`when`(apply)
            .apply(
                any(IngestionRun::class.java) ?: IngestionRun(EventSource.TIMEPAD),
                any(Instant::class.java) ?: Instant.EPOCH,
                any(ProviderFetchResult.Complete::class.java)
                    ?: ProviderFetchResult.Complete(emptyList(), emptySet(), observedCount = 0),
                isNull<PreparedTimepadPoint>(),
            )
        `when`(apply.reconcileApplyFailure(1L, "apply_failed")).thenReturn(durableSuccess)

        val result = service.runProvider(provider)

        assertEquals(IngestionStatus.SUCCESS, result.status)
        verify(apply).reconcileApplyFailure(1L, "apply_failed")
        verify(runs, times(1)).save(any(IngestionRun::class.java) ?: IngestionRun(EventSource.TIMEPAD))
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

    @Test
    fun `first needy event gets one pretransaction attempt and failure never falls through`() {
        val events = listOf(
            raw("online").copy(isOnline = true),
            raw("blank").copy(address = " "),
            raw("source").copy(latitude = 12.0),
            raw("first"), raw("second"),
        )
        val provider = ControlledProvider { ProviderFetchResult.Complete(events, emptySet(), 5) }
        val (service, apply, upsert) = service(provider)
        doAnswer {
            assertFalse(TransactionSynchronizationManager.isActualTransactionActive())
            throw IllegalStateException("private-failure")
        }.`when`(upsert).prepareTimepadPoint(events[3], null)

        service.runProvider(provider)

        verify(upsert).prepareTimepadPoint(events[3], null)
        verify(upsert, times(1)).prepareTimepadPoint(any(RawEvent::class.java) ?: events[0], isNull())
        verify(apply).apply(
            any(IngestionRun::class.java) ?: IngestionRun(EventSource.TIMEPAD),
            org.mockito.ArgumentMatchers.eq(Instant.parse("2026-10-21T10:00:00Z")) ?: Instant.EPOCH,
            org.mockito.ArgumentMatchers.eq(ProviderFetchResult.Complete(events, emptySet(), 5))
                ?: ProviderFetchResult.Complete(emptyList(), emptySet(), 0),
            isNull(),
        )
    }

    @Test
    fun `successful preparation is separate from source event and permits later venue next run`() {
        val events = listOf(raw("first"), raw("second"))
        val savedRows = mutableListOf<Meeting>()
        val provider = ControlledProvider { ProviderFetchResult.Complete(events, emptySet(), 2) }
        val (service, apply, upsert) = service(provider, saved = savedRows)
        val prepared = PreparedTimepadPoint("first", events[0].address, null, Coordinates(12.0, 34.0))
        org.mockito.Mockito.`when`(upsert.prepareTimepadPoint(events.first(), null)).thenReturn(prepared)
        doAnswer {
            assertEquals(prepared, it.getArgument(3))
            assertEquals(0.0, events.first().latitude)
            savedRows.add(saved(events.first()).also { row -> row.latitude = 12.0; row.longitude = 34.0 })
            it.getArgument<IngestionRun>(0)
        }.`when`(apply).apply(
            any(IngestionRun::class.java) ?: IngestionRun(EventSource.TIMEPAD),
            any(Instant::class.java) ?: Instant.EPOCH,
            any(ProviderFetchResult.Complete::class.java) ?: ProviderFetchResult.Complete(emptyList(), emptySet(), 0),
            org.mockito.ArgumentMatchers.eq(prepared) ?: prepared,
        )
        service.runProvider(provider)
        service.runProvider(provider)
        verify(upsert).prepareTimepadPoint(events.first(), null)
        verify(upsert).prepareTimepadPoint(events.last(), null)
    }

    @Test
    fun `no candidate or rejected attempt never invokes a second candidate`() {
        for (events in listOf(emptyList(), listOf(raw("online").copy(isOnline = true)),
            listOf(raw("first"), raw("second")))) {
            val provider = ControlledProvider { ProviderFetchResult.Complete(events, emptySet(), events.size) }
            val (service, _, upsert) = service(provider)
            service.runProvider(provider)
            if (events.firstOrNull()?.isOnline == false) {
                verify(upsert).prepareTimepadPoint(events.first(), null)
                verify(upsert, never()).prepareTimepadPoint(events.last(), null)
            } else verifyNoInteractions(upsert)
        }
    }

    @Test
    fun `saved state is copied before provider fetch and only first needy is selected`() {
        val existing = saved(raw("known")).also { it.latitude = 12.0; it.longitude = 34.0 }
        val events = listOf(raw("known"), raw("needy"), raw("later"))
        val provider = ControlledProvider {
            // A managed-object mutation must not rewrite the already captured evidence.
            existing.address = "Different road 2"
            existing.latitude = 0.0
            ProviderFetchResult.Complete(events, emptySet(), 3)
        }
        val (service, _, upsert) = service(provider, saved = listOf(existing))
        service.runProvider(provider)
        verify(upsert).prepareTimepadPoint(events[1], null)
        verify(upsert, never()).prepareTimepadPoint(events[0], SavedTimepadVenue.from(existing))
        verify(upsert, never()).prepareTimepadPoint(events[2], null)
        org.mockito.Mockito.verifyNoMoreInteractions(upsert)
    }

    @Test
    fun `needy predicate and locked point priority fail closed on changed venue and evidence`() {
        val event = raw("test")
        val snapshot = SavedTimepadVenue.from(saved(event))
        assertTrue(TimepadCoordinateEnrichment.needsPoint(event, snapshot))
        for (raw in listOf(event.copy(isOnline = true), event.copy(address = ""),
            event.copy(latitude = 0.0, longitude = 34.0))) {
            assertFalse(TimepadCoordinateEnrichment.needsPoint(raw, snapshot))
        }
        val accepted = snapshot.copy(latitude = 12.0, longitude = 34.0)
        assertFalse(TimepadCoordinateEnrichment.needsPoint(event, accepted))
        assertTrue(TimepadCoordinateEnrichment.needsPoint(event.copy(address = "Other 1"), accepted))
        assertTrue(TimepadCoordinateEnrichment.needsPoint(event, accepted.copy(online = true)))
        val point = Coordinates(13.0, 35.0)
        val prepared = PreparedTimepadPoint(event.sourceExternalId, event.address, snapshot, point)
        assertEquals(point, TimepadCoordinateEnrichment.select(event, snapshot, prepared))
        assertEquals(Coordinates(12.0, 34.0), TimepadCoordinateEnrichment.select(event, accepted, prepared))
        assertEquals(Coordinates(14.0, 36.0), TimepadCoordinateEnrichment.select(
            event.copy(latitude = 14.0, longitude = 36.0), accepted, prepared,
        ))
        for (changed in listOf(
            snapshot.copy(id = 2), snapshot.copy(externalId = "other"),
            snapshot.copy(source = EventSource.MANUAL), snapshot.copy(address = "Other 1"),
            snapshot.copy(online = true), snapshot.copy(latitude = Double.NaN),
            snapshot.copy(ingestedAt = snapshot.ingestedAt!!.plusSeconds(1)), null,
        )) {
            assertEquals(Coordinates(0.0, 0.0), TimepadCoordinateEnrichment.select(event, changed, prepared))
        }
        val absent = prepared.copy(expectedSaved = null)
        assertEquals(point, TimepadCoordinateEnrichment.select(event, null, absent))
        assertEquals(Coordinates(0.0, 0.0), TimepadCoordinateEnrichment.select(event, snapshot, absent))
        for (invalid in listOf(Coordinates(Double.NaN, 1.0), Coordinates(1.0, Double.POSITIVE_INFINITY),
            Coordinates(91.0, 1.0), Coordinates(1.0, -181.0), Coordinates(0.0, 0.0))) {
            assertFalse(TimepadCoordinateEnrichment.valid(invalid.latitude, invalid.longitude))
        }
    }

    private fun raw(id: String) = RawEvent(
        id, "Synthetic test", "", "", 1_790_000_000_000, "Test street 1",
        0.0, 0.0, "https://example.test/event/$id", false, timepadGroups = listOf("IT"),
    )

    private fun saved(raw: RawEvent) = Meeting(
        raw.title, "", "", raw.startsAtEpochMs, "01.01.2026", raw.address, raw.latitude, raw.longitude,
        source = EventSource.TIMEPAD, sourceExternalId = raw.sourceExternalId,
        ingestedAt = java.time.LocalDateTime.of(2026, 10, 25, 1, 0),
    ).also { it.id = 1 }

    private fun service(
        provider: EventProvider,
        runRepository: IngestionRunRepository = mock(IngestionRunRepository::class.java),
        saved: List<Meeting> = emptyList(),
    ): Triple<IngestionService, TimepadCatalogApplyService, MeetingUpsertService> {
        val meetingRepository = mock(MeetingRepository::class.java)
        `when`(
            meetingRepository.findTop501BySourceAndSourceExternalIdNotNullOrderByIdAsc(EventSource.TIMEPAD),
        ).thenReturn(saved)
        doAnswer {
            it.getArgument<IngestionRun>(0).also { run -> if (run.id == null) run.id = 1L }
        }
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
