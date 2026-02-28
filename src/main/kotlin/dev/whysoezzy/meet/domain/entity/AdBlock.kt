package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*

@Entity
@Table(name = "ad_blocks")
class AdBlock : BaseEntity() {

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    var type: AdBlockType = AdBlockType.TEXT

    @Column(name = "is_active", nullable = false)
    var isActive: Boolean = true

    // Общие поля
    @Column(length = 255)
    var title: String? = null

    @Column(columnDefinition = "TEXT")
    var description: String? = null

    @Column(name = "action_text", length = 100)
    var actionText: String? = null

    @Column(name = "action_url", length = 500)
    var actionUrl: String? = null

    @ManyToMany
    @JoinTable(
        name = "ad_block_communities",
        joinColumns = [JoinColumn(name = "ad_block_id")],
        inverseJoinColumns = [JoinColumn(name = "community_id")]
    )
    var communities: MutableSet<Community> = mutableSetOf()

    @ManyToMany
    @JoinTable(
        name = "ad_block_users",
        joinColumns = [JoinColumn(name = "ad_block_id")],
        inverseJoinColumns = [JoinColumn(name = "user_id")]
    )
    var users: MutableSet<User> = mutableSetOf()
}

enum class AdBlockType {
    COMMUNITIES,
    TEXT,
    PEOPLE
}