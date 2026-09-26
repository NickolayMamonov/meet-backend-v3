package dev.whysoezzy.meet.domain.entity

import dev.whysoezzy.meet.catalog.RealCatalogStateEntity
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

    @Column(name = "demo_catalog_key", length = 160, updatable = false)
    var demoCatalogKey: String? = null,

    @Column(name = "real_catalog_key", length = 80)
    var realCatalogKey: String? = null,

    @Column(name = "real_catalog_item_key", length = 120)
    var realCatalogItemKey: String? = null,

    @Column(name = "real_catalog_active")
    var realCatalogActive: Boolean? = null,

    @Column(name = "real_catalog_fingerprint", length = 64)
    var realCatalogFingerprint: String? = null,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "real_catalog_key", insertable = false, updatable = false)
    var realCatalogState: RealCatalogStateEntity? = null,
    
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
