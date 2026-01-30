package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*

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
    
) : BaseEntity()

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
