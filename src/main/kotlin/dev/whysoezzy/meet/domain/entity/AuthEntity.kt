package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "otp_codes")
class OtpCode(
    @Column(nullable = false, length = 20)
    var phone: String,
    @Column(nullable = false, length = 10)
    var code: String,
    @Column(name = "expires_at", nullable = false)
    var expiresAt: LocalDateTime,
    @Column(name = "is_used", nullable = false)
    var isUsed: Boolean = false,
    @Column(name = "created_at", nullable = false)
    var createdAt: LocalDateTime = LocalDateTime.now(),
) {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null

    val isExpired: Boolean
        get() = LocalDateTime.now().isAfter(expiresAt)

    val isValid: Boolean
        get() = !isUsed && !isExpired
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
