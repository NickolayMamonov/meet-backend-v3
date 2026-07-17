package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.OtpCode
import dev.whysoezzy.meet.domain.entity.RefreshToken
import jakarta.persistence.LockModeType
import org.springframework.data.jpa.repository.Lock
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Modifying
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import org.springframework.stereotype.Repository
import java.time.LocalDateTime

@Repository
interface OtpRepository : JpaRepository<OtpCode, Long> {

    @Query("""
        SELECT o FROM OtpCode o
        WHERE o.phone = :phone
          AND o.code = :code
          AND o.isUsed = false
          AND o.expiresAt > :now
        ORDER BY o.createdAt DESC
    """)
    fun findValidCode(
        @Param("phone") phone: String,
        @Param("code") code: String,
        @Param("now") now: LocalDateTime = LocalDateTime.now()
    ): OtpCode?

    @Modifying
    @Query("DELETE FROM OtpCode o WHERE o.expiresAt < :now")
    fun deleteExpired(@Param("now") now: LocalDateTime)
}

@Repository
interface RefreshTokenRepository : JpaRepository<RefreshToken, Long> {

    fun findByTokenHash(tokenHash: String): RefreshToken?

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    fun findWithLockByTokenHash(tokenHash: String): RefreshToken?

    @Modifying
    @Query("DELETE FROM RefreshToken r WHERE r.user.id = :userId")
    fun deleteAllByUserId(@Param("userId") userId: Long)

    @Modifying
    @Query("DELETE FROM RefreshToken r WHERE r.expiresAt < :now")
    fun deleteExpired(@Param("now") now: LocalDateTime)
}
