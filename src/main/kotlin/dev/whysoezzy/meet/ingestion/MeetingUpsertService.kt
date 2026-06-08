package dev.whysoezzy.meet.ingestion

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.repository.MeetingRepository
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

enum class UpsertResult { CREATED, UPDATED, SKIPPED }

@Service
class MeetingUpsertService(
    private val meetingRepository: MeetingRepository,
    private val tagRepository: dev.whysoezzy.meet.domain.repository.TagRepository,
    private val topicClassifier: TopicClassifier,
    @Value("\${app.ingestion.zone:Europe/Moscow}") private val zoneId: String,
    @Value("\${app.ingestion.only-matching-topics:true}") private val onlyMatchingTopics: Boolean,
) {
    private val dateFormatter = DateTimeFormatter.ofPattern("dd.MM.yyyy")

    @Transactional
    fun upsert(source: EventSource, raw: RawEvent): UpsertResult {
        val topics = topicClassifier.classify(raw)
        if (topics.isEmpty() && onlyMatchingTopics) return UpsertResult.SKIPPED

        val dateLabel = Instant.ofEpochMilli(raw.startsAtEpochMs)
            .atZone(ZoneId.of(zoneId)).format(dateFormatter)
        val dedup = dedupHash(raw, dateLabel)
        val tags = resolveTags(topics)

        val existing = meetingRepository.findBySourceAndSourceExternalId(source, raw.sourceExternalId)
        return if (existing != null) {
            existing.title = raw.title
            existing.description = raw.description
            existing.imageUrl = raw.imageUrl
            existing.time = raw.startsAtEpochMs
            existing.date = dateLabel
            existing.address = raw.address
            existing.latitude = raw.latitude
            existing.longitude = raw.longitude
            existing.externalUrl = raw.externalUrl
            existing.isOnline = raw.isOnline
            existing.ingestedAt = LocalDateTime.now()
            existing.dedupHash = dedup
            existing.tags.clear()
            existing.tags.addAll(tags)
            meetingRepository.save(existing)
            UpsertResult.UPDATED
        } else {
            val meeting = Meeting(
                title = raw.title,
                description = raw.description,
                imageUrl = raw.imageUrl,
                time = raw.startsAtEpochMs,
                date = dateLabel,
                address = raw.address,
                latitude = raw.latitude,
                longitude = raw.longitude,
                tags = tags.toMutableSet(),
                source = source,
                sourceExternalId = raw.sourceExternalId,
                externalUrl = raw.externalUrl,
                isOnline = raw.isOnline,
                ingestedAt = LocalDateTime.now(),
                dedupHash = dedup,
            )
            meetingRepository.save(meeting)
            UpsertResult.CREATED
        }
    }

    /** Находит тег по тексту или создаёт новый. */
    private fun resolveTags(topics: Set<String>): MutableSet<dev.whysoezzy.meet.domain.entity.Tag> =
        topics.map { text ->
            tagRepository.findByText(text)
                ?: tagRepository.save(dev.whysoezzy.meet.domain.entity.Tag(text = text))
        }.toMutableSet()

    private fun dedupHash(raw: RawEvent, dateLabel: String): String {
        val basis = "${raw.title.trim().lowercase()}|$dateLabel|${raw.externalUrl ?: ""}"
        return MessageDigest.getInstance("SHA-256")
            .digest(basis.toByteArray())
            .joinToString("") { "%02x".format(it) }
            .take(64)
    }
}