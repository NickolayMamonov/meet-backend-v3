package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "meetings")
class Meeting(

    @Column(nullable = false, length = 300)
    var title: String,

    @Column(nullable = false, columnDefinition = "TEXT")
    var description: String,

    @Column(name = "image_url", columnDefinition = "TEXT")
    var imageUrl: String,

    @Column(nullable = false)
    var time: Long, // Unix timestamp in milliseconds

    @Column(nullable = false, length = 50)
    var date: String, // Formatted date string (e.g., "01.02.2025")

    @Column(nullable = false, columnDefinition = "TEXT")
    var address: String,

    @Column(nullable = false)
    var latitude: Double,

    @Column(nullable = false)
    var longitude: Double,

    @Column(nullable = false)
    var capacity: Int = 100,

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    var status: MeetingStatus = MeetingStatus.ACTIVE,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "person_host_id")
    var personHost: User? = null,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "community_host_id")
    var communityHost: Community? = null,

    @ManyToMany
    @JoinTable(
        name = "meeting_tags",
        joinColumns = [JoinColumn(name = "meeting_id")],
        inverseJoinColumns = [JoinColumn(name = "tag_id")]
    )
    var tags: MutableSet<Tag> = mutableSetOf(),

    @ManyToMany
    @JoinTable(
        name = "meeting_participants",
        joinColumns = [JoinColumn(name = "meeting_id")],
        inverseJoinColumns = [JoinColumn(name = "user_id")]
    )
    var participants: MutableSet<User> = mutableSetOf(),

    // --- Внешний источник (агрегация) ---
    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    var source: EventSource = EventSource.MANUAL,

    @Column(name = "source_external_id", length = 255)
    var sourceExternalId: String? = null,

    @Column(name = "external_url", columnDefinition = "TEXT")
    var externalUrl: String? = null,

    @Column(name = "is_online", nullable = false)
    var isOnline: Boolean = false,

    @Column(name = "ingested_at")
    var ingestedAt: LocalDateTime? = null,

    @Column(name = "dedup_hash", length = 64)
    var dedupHash: String? = null,

    @Column(name = "ends_at")
    var endsAt: Long? = null, // Unix timestamp in milliseconds; null falls back to time for discovery
    
) : BaseEntity() {
    
    fun addParticipant(user: User) {
        if (participants.size >= capacity) {
            throw MeetingCapacityExceededException()
        }
        participants.add(user)
    }
    
    fun removeParticipant(user: User) {
        participants.remove(user)
    }
    
    fun isFull(): Boolean = participants.size >= capacity
    
    fun isActive(): Boolean = status == MeetingStatus.ACTIVE
}

class MeetingCapacityExceededException : RuntimeException("Meeting is at full capacity")

enum class MeetingStatus {
    ACTIVE,
    CANCELLED,
    FINISHED
}

enum class EventSource {
    MANUAL,   // создано вручную / user-generated (будущее)
    TIMEPAD   // подтянуто из Timepad
}
