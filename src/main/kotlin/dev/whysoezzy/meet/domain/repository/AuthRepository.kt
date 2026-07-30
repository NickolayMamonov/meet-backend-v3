package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.AuthIdentity
import dev.whysoezzy.meet.domain.entity.AuthIdentityType
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
interface AuthIdentityRepository : JpaRepository<AuthIdentity, Long> {
    fun findByTypeAndNormalizedIdentifier(
        type: AuthIdentityType,
        normalizedIdentifier: String,
    ): AuthIdentity?

    @Query("SELECT identity FROM AuthIdentity identity WHERE identity.user.id = :userId AND identity.type = :type")
    fun findByUserIdAndType(
        @Param("userId") userId: Long,
        @Param("type") type: AuthIdentityType,
    ): AuthIdentity?
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
