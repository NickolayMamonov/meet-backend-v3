package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import dev.whysoezzy.meet.domain.entity.IngestionStatus
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.ingestion.ProviderFetchResult
import dev.whysoezzy.meet.ingestion.RawEvent
import dev.whysoezzy.meet.ingestion.TimepadCatalogApplyService
import dev.whysoezzy.meet.ingestion.Coordinates
import dev.whysoezzy.meet.ingestion.EventProvider
import dev.whysoezzy.meet.ingestion.FetchContext
import dev.whysoezzy.meet.ingestion.GeocodingService
import dev.whysoezzy.meet.ingestion.IngestionService
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import org.springframework.dao.DataIntegrityViolationException
import org.junit.jupiter.api.assertThrows
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import org.springframework.transaction.support.TransactionSynchronizationManager
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.verify
import org.mockito.Mockito.times
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class TimepadCatalogPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var catalogApply: TimepadCatalogApplyService
    @Autowired
    private lateinit var ingestionRuns: IngestionRunRepository
    @Autowired private lateinit var ingestion: IngestionService
    @Autowired private lateinit var transactions: PlatformTransactionManager
    @MockitoBean private lateinit var geocoding: GeocodingService

    @BeforeEach
    fun clearDatabase() = resetDatabase()

    @ParameterizedTest
    @ValueSource(strings = ["timestamp", "address", "replacement", "insertion"])
    fun `HTTP preparation holds no transaction or row lock and concurrent saved change rejects its point`(
        change: String,
    ) {
        val event = raw("concurrent-http", "Synthetic backend event")
        if (change != "insertion") {
            catalogApply.apply(
                ingestionRuns.save(IngestionRun(EventSource.TIMEPAD)), Instant.now(),
                ProviderFetchResult.Complete(listOf(event), emptySet(), 1),
            )
        }
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val observed = AtomicReference<Instant>()
        doAnswer {
            assertFalse(TransactionSynchronizationManager.isActualTransactionActive())
            entered.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
            Coordinates(12.0, 34.0)
        }.`when`(geocoding).geocodeTimepad(event.address)
        val provider = object : EventProvider {
            override fun source() = EventSource.TIMEPAD
            override fun fetch(context: FetchContext): ProviderFetchResult {
                observed.set(context.observedAt)
                return ProviderFetchResult.Complete(listOf(event), emptySet(), 1)
            }
        }
        val executor = Executors.newSingleThreadExecutor()
        try {
            val result = executor.submit<IngestionRun> { ingestion.runProvider(provider) }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            TransactionTemplate(transactions).apply { timeout = 2 }.executeWithoutResult {
                jdbcTemplate.execute("SET LOCAL lock_timeout = '1s'")
                val locked = meetings.findForUpdateBySourceAndSourceExternalId(
                    EventSource.TIMEPAD, event.sourceExternalId,
                )
                when (change) {
                    "timestamp" -> {
                        locked!!.ingestedAt = locked.ingestedAt!!.plusSeconds(1)
                        meetings.saveAndFlush(locked)
                    }
                    "address" -> {
                        locked!!.address = "Other synthetic road 2"
                        meetings.saveAndFlush(locked)
                    }
                    else -> {
                        if (locked != null) {
                            meetings.delete(locked)
                            meetings.flush()
                        }
                        meetings.saveAndFlush(
                            Meeting(
                                event.title, "", "", event.startsAtEpochMs, "01.01.2026",
                                event.address, 0.0, 0.0, source = EventSource.TIMEPAD,
                                sourceExternalId = event.sourceExternalId,
                                ingestedAt = java.time.LocalDateTime.now(),
                            ),
                        )
                    }
                }
            }
            release.countDown()
            val run = result.get(10, TimeUnit.SECONDS)
            assertEquals(IngestionStatus.SUCCESS, run.status)
            assertEquals(1, run.fetchedCount)
            assertEquals(1, run.updatedCount)
            val saved = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, event.sourceExternalId)!!
            assertEquals(Coordinates(0.0, 0.0), Coordinates(saved.latitude, saved.longitude))
            assertEquals(observed.get().plusSeconds(72 * 60 * 60).toEpochMilli(), saved.timepadEligibleUntilMs)
            verify(geocoding, times(1)).geocodeTimepad(event.address)
        } finally {
            release.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test
    fun `complete observation upserts idempotently and revokes rejected saved event`() {
        val observedAt = Instant.parse("2026-10-21T10:00:00Z")
        val first = meetings.save(
            Meeting(
                title = "Legacy Timepad row",
                description = "Old",
                imageUrl = "",
                time = observedAt.toEpochMilli() + 60_000,
                date = "21.10.2026",
                address = "Moscow",
                latitude = 0.0,
                longitude = 0.0,
                source = EventSource.TIMEPAD,
                sourceExternalId = "42",
                timepadEligibleUntilMs = observedAt.toEpochMilli() + 1,
            ),
        )
        val rejected = meetings.save(
            Meeting(
                title = "Rejected saved row",
                description = "",
                imageUrl = "",
                time = observedAt.toEpochMilli() + 60_000,
                date = "21.10.2026",
                address = "Moscow",
                latitude = 0.0,
                longitude = 0.0,
                source = EventSource.TIMEPAD,
                sourceExternalId = "legacy-rejected",
                timepadEligibleUntilMs = observedAt.toEpochMilli() + 72 * 60 * 60 * 1000,
            ),
        )
        val event = raw("42", "Updated Kotlin backend meetup")
        val run = ingestionRuns.save(IngestionRun(source = EventSource.TIMEPAD))

        catalogApply.apply(
            run,
            observedAt,
            ProviderFetchResult.Complete(
                accepted = listOf(event),
                rejectedSavedExternalIds = setOf("legacy-rejected"),
                observedCount = 2,
            ),
        )
        val saved = meetings.findBySourceAndSourceExternalId(EventSource.TIMEPAD, "42")!!
        assertEquals(first.id, saved.id)
        assertEquals("Updated Kotlin backend meetup", saved.title)
        assertEquals(observedAt.toEpochMilli() + 72 * 60 * 60 * 1000, saved.timepadEligibleUntilMs)
        assertEquals(IngestionStatus.SUCCESS, run.status)
        assertNull(meetings.findById(rejected.id!!).orElseThrow().timepadEligibleUntilMs)
        assertEquals(2, meetings.count())
    }

    @Test
    fun `failed later upsert rolls back earlier catalog write and success journal`() {
        val observedAt = Instant.parse("2026-10-21T10:00:00Z")
        val run = ingestionRuns.save(IngestionRun(source = EventSource.TIMEPAD))
        val tooLongTitle = raw("43", "x".repeat(301))

        assertThrows<RuntimeException> {
            catalogApply.apply(
                run,
                observedAt,
                ProviderFetchResult.Complete(
                    accepted = listOf(raw("42", "Valid Kotlin event"), tooLongTitle),
                    rejectedSavedExternalIds = emptySet(),
                    observedCount = 2,
                ),
            )
        }

        assertEquals(0, meetings.count())
        assertEquals(IngestionStatus.RUNNING, ingestionRuns.findById(run.id!!).orElseThrow().status)

        val reconciled = catalogApply.reconcileApplyFailure(run.id!!, "apply_failed")

        assertEquals(IngestionStatus.FAILED, reconciled.status)
        assertEquals("Timepad apply failed: apply_failed", reconciled.errorMessage)
        assertEquals(0, reconciled.fetchedCount)
        assertNotNull(reconciled.finishedAt)
        assertEquals(IngestionStatus.FAILED, ingestionRuns.findById(run.id!!).orElseThrow().status)
        assertEquals(0, meetings.count())
    }

    @Test
    fun `reconciliation preserves committed success after lost acknowledgement without replay`() {
        val observedAt = Instant.parse("2026-10-21T10:00:00Z")
        val run = ingestionRuns.save(IngestionRun(source = EventSource.TIMEPAD))

        assertThrows<CommitAcknowledgementLostException> {
            applyWithLostAcknowledgement(run, observedAt)
        }

        assertEquals(IngestionStatus.SUCCESS, ingestionRuns.findById(run.id!!).orElseThrow().status)
        run.status = IngestionStatus.RUNNING

        val reconciled = catalogApply.reconcileApplyFailure(run.id!!, "apply_failed")

        assertEquals(IngestionStatus.SUCCESS, reconciled.status)
        assertEquals(1, reconciled.createdCount)
        assertEquals(IngestionStatus.SUCCESS, ingestionRuns.findById(run.id!!).orElseThrow().status)
        assertEquals(1, meetings.count())
    }

    private fun applyWithLostAcknowledgement(run: IngestionRun, observedAt: Instant): Nothing {
        catalogApply.apply(
            run,
            observedAt,
            ProviderFetchResult.Complete(
                accepted = listOf(raw("42", "Committed Kotlin event")),
                rejectedSavedExternalIds = emptySet(),
                observedCount = 1,
            ),
        )
        throw CommitAcknowledgementLostException()
    }

    private class CommitAcknowledgementLostException : RuntimeException()

    private fun raw(id: String, title: String) = RawEvent(
        sourceExternalId = id,
        title = title,
        description = "Owned factual description",
        imageUrl = "https://assets.example/timepad-assets/v1/it.png",
        startsAtEpochMs = Instant.parse("2026-10-22T10:00:00Z").toEpochMilli(),
        endsAtEpochMs = null,
        address = "ул. Пример, 1",
        latitude = 0.0,
        longitude = 0.0,
        externalUrl = "https://timepad.ru/event/$id/",
        isOnline = false,
        topicKeywords = emptySet(),
        timepadGroups = listOf("IT"),
    )
}
