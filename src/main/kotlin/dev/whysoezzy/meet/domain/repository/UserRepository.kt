package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.User
import jakarta.persistence.LockModeType
import org.springframework.data.jpa.repository.Lock
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface UserRepository : JpaRepository<User, Long> {
    fun findByPhone(phone: String): User?

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    fun findWithLockById(id: Long): User?
}
