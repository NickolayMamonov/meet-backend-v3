package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.api.error.ConflictException
import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.api.error.PushUnavailableException
import org.springframework.dao.DataAccessException
import org.springframework.stereotype.Service
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.sql.SQLException
import java.time.Clock
import java.time.Instant
import java.util.UUID

data class PushInstallationMutation(
    val installation: PushInstallationRecord,
    val created: Boolean = false,
)

@Service
class PushInstallationService(
    private val store: PushInstallationStore,
    transactionManager: PlatformTransactionManager,
    private val clock: Clock,
) {
    private val transaction = TransactionTemplate(transactionManager).apply {
        timeout = 5
    }

    fun register(userId: Long, fid: Fid): PushInstallationMutation =
        retry {
            val now = clock.instant().truncatedTo(java.time.temporal.ChronoUnit.MILLIS)
            store.setLockTimeout()
            val owners = (store.ownerIdsForFid(fid) + userId).distinct().sorted()
            owners.forEach(store::lockUser)
            val holder = store.findByFid(fid, forUpdate = true)
            if (holder?.userId == userId) {
                val current = requireNotNull(store.heartbeat(holder.id, userId, now))
                PushInstallationMutation(current)
            } else {
                holder?.let { store.transfer(it.id, now) }
                PushInstallationMutation(store.insert(UUID.randomUUID(), userId, fid, now), created = true)
            }
        }

    fun rotate(userId: Long, installationId: UUID, fid: Fid): PushInstallationMutation =
        retry {
            val now = clock.instant().truncatedTo(java.time.temporal.ChronoUnit.MILLIS)
            store.setLockTimeout()
            val ownerIds = (store.ownerIdsForFid(fid) + userId).distinct().sorted()
            ownerIds.forEach(store::lockUser)
            val current = store.findById(installationId, forUpdate = true)
                ?: throw NotFoundException("Push installation not found")
            if (
                current.userId != userId ||
                current.status !in setOf(
                    InstallationStatus.ACTIVE,
                    InstallationStatus.UNREGISTERED,
                    InstallationStatus.INVALID,
                    InstallationStatus.EXPIRED,
                )
            ) {
                throw NotFoundException("Push installation not found")
            }
            val holder = store.findByFid(fid, forUpdate = true)
            if (holder != null && holder.id != installationId) store.transfer(holder.id, now)
            PushInstallationMutation(
                requireNotNull(store.activate(installationId, userId, fid, now)),
            )
        }

    fun unregister(userId: Long, installationId: UUID) {
        retry {
            val now = clock.instant().truncatedTo(java.time.temporal.ChronoUnit.MILLIS)
            store.setLockTimeout()
            store.lockUser(userId)
            val current = store.findById(installationId, forUpdate = true)
                ?: throw NotFoundException("Push installation not found")
            if (
                current.userId != userId ||
                current.status !in setOf(
                    InstallationStatus.ACTIVE,
                    InstallationStatus.UNREGISTERED,
                    InstallationStatus.INVALID,
                    InstallationStatus.EXPIRED,
                )
            ) {
                throw NotFoundException("Push installation not found")
            }
            if (current.status == InstallationStatus.ACTIVE) store.unregister(installationId, userId, now)
            Unit
        }
    }

    private fun <T> retry(block: () -> T): T {
        var last: Throwable? = null
        repeat(3) {
            try {
                return requireNotNull(transaction.execute { block() })
            } catch (exception: Throwable) {
                if (exception is NotFoundException || exception is ConflictException) throw exception
                if (!isRetryable(exception)) throw exception
                last = exception
            }
        }
        throw PushUnavailableException()
    }

    private fun isRetryable(exception: Throwable): Boolean {
        var current: Throwable? = exception
        while (current != null) {
            if (current is SQLException && current.sqlState in RETRYABLE_STATES) return true
            if (current is DataAccessException && current.cause is SQLException &&
                (current.cause as SQLException).sqlState in RETRYABLE_STATES
            ) return true
            current = current.cause
        }
        return false
    }

    private companion object {
        val RETRYABLE_STATES = setOf("23505", "40001", "40P01")
    }
}
