package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "auth_identities")
class AuthIdentity(
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id", nullable = false)
    val user: User,
    @Enumerated(EnumType.STRING)
    @Column(name = "type", nullable = false, length = 16)
    val type: AuthIdentityType,
    @Column(name = "normalized_identifier", nullable = false, length = 254)
    val normalizedIdentifier: String,
    @Column(name = "created_at", nullable = false)
    val createdAt: LocalDateTime = LocalDateTime.now(),
) {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null
        protected set
}

enum class AuthIdentityType {
    PHONE,
    EMAIL,
}

@Entity
@Table(name = "refresh_tokens")
class RefreshToken(
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id", nullable = false)
    var user: User,
    @Column(name = "token_hash", nullable = false, unique = true, length = 64)
    var tokenHash: String,
    @Column(name = "expires_at", nullable = false)
    var expiresAt: LocalDateTime,
    @Column(name = "created_at", nullable = false)
    var createdAt: LocalDateTime = LocalDateTime.now(),
    @Column(name = "auth_version", nullable = false)
    var authVersion: Long = 0,
) {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null

    val isExpired: Boolean
        get() = LocalDateTime.now().isAfter(expiresAt)
}
