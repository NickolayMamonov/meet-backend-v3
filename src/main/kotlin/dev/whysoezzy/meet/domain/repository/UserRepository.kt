package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.User
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface UserRepository : JpaRepository<User, Long> {
    fun findByPhone(phone: String): User?
    fun existsByIdAndDeletedAtIsNull(id: Long): Boolean
}
