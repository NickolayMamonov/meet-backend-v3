package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*

@Entity
@Table(name = "communities")
class Community(
    
    @Column(nullable = false, length = 255)
    var name: String,
    
    @Column(nullable = false, columnDefinition = "TEXT")
    var description: String,
    
    @Column(name = "image_url", columnDefinition = "TEXT")
    var imageUrl: String,
    
    @ManyToMany
    @JoinTable(
        name = "community_tags",
        joinColumns = [JoinColumn(name = "community_id")],
        inverseJoinColumns = [JoinColumn(name = "tag_id")]
    )
    var tags: MutableSet<Tag> = mutableSetOf(),
    
    @ManyToMany
    @JoinTable(
        name = "community_subscribers",
        joinColumns = [JoinColumn(name = "community_id")],
        inverseJoinColumns = [JoinColumn(name = "user_id")]
    )
    var subscribers: MutableSet<User> = mutableSetOf(),
    
    @OneToMany(mappedBy = "communityHost")
    var meetings: MutableList<Meeting> = mutableListOf()
    
) : BaseEntity() {
    
    val subscribersCount: Int
        get() = subscribers.size
    
    fun getActiveMeetings(): List<Meeting> {
        return meetings.filter { it.status == MeetingStatus.ACTIVE }
    }
}
