package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "users")
class User(

    @Column(nullable = false, length = 100)
    var name: String,

    @Column(nullable = false, length = 100)
    var surname: String,

    @Column(nullable = false, unique = true, length = 20)
    var phone: String,

    @Column(length = 255)
    var email: String? = null,

    @Column(length = 100)
    var city: String = "",

    @Column(name = "avatar_url")
    var avatarUrl: String? = null,

    @Column(columnDefinition = "TEXT")
    var bio: String = "",

    @Column(length = 100)
    var role: String? = null,

    // Настройки профиля
    @Column(name = "show_communities", nullable = false)
    var showCommunities: Boolean = true,

    @Column(name = "show_meetings", nullable = false)
    var showMeetings: Boolean = true,

    @Column(name = "notifications_enabled", nullable = false)
    var notificationsEnabled: Boolean = true,

    // Push-уведомления
    @Column(name = "fcm_token", columnDefinition = "TEXT")
    var fcmToken: String? = null,

    // Soft delete
    @Column(name = "deleted_at")
    var deletedAt: LocalDateTime? = null,

    @ManyToMany
    @JoinTable(
        name = "user_interests",
        joinColumns = [JoinColumn(name = "user_id")],
        inverseJoinColumns = [JoinColumn(name = "tag_id")]
    )
    var interests: MutableSet<Tag> = mutableSetOf(),

    @OneToMany(mappedBy = "user", cascade = [CascadeType.ALL], orphanRemoval = true)
    var socialMedia: MutableList<UserSocialMedia> = mutableListOf(),

    @ManyToMany(mappedBy = "subscribers")
    var subscribedCommunities: MutableSet<Community> = mutableSetOf(),

    @ManyToMany(mappedBy = "participants")
    var participatingMeetings: MutableSet<Meeting> = mutableSetOf()

) : BaseEntity() {

    val isDeleted: Boolean
        get() = deletedAt != null
}

@Entity
@Table(name = "user_social_media")
class UserSocialMedia(

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id", nullable = false)
    var user: User,

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 50)
    var platform: SocialMediaType,

    @Column(nullable = false, length = 255)
    var username: String

) : BaseEntity()

enum class SocialMediaType {
    TELEGRAM,
    HABR
}
