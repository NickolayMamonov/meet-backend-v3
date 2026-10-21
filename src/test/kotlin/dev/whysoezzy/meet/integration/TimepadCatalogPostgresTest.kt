package dev.whysoezzy.meet.integration

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.IngestionRun
import dev.whysoezzy.meet.domain.entity.IngestionStatus
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.repository.IngestionRunRepository
import dev.whysoezzy.meet.ingestion.ProviderFetchResult
import dev.whysoezzy.meet.ingestion.RawEvent
import dev.whysoezzy.meet.ingestion.TimepadCatalogApplyService
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import java.time.Instant
import org.springframework.dao.DataIntegrityViolationException
import org.junit.jupiter.api.assertThrows
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class TimepadCatalogPostgresTest : IntegrationTestSupport() {
    @Autowired
    private lateinit var catalogApply: TimepadCatalogApplyService
    @Autowired
    private lateinit var ingestionRuns: IngestionRunRepository

    @BeforeEach
    fun clearDatabase() = resetDatabase()

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
