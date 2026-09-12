package dev.whysoezzy.meet.service.push

import org.junit.jupiter.api.Test
import org.mockito.Answers
import org.mockito.Mockito
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.TransactionDefinition
import org.springframework.transaction.TransactionStatus
import org.springframework.transaction.support.SimpleTransactionStatus
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

class PushInstallationServiceTest {
    private val now = Instant.parse("2026-09-11T20:00:00Z")
    private val clock = Clock.fixed(now, ZoneOffset.UTC)

    @Test
    fun `register heartbeats an active installation owned by the same user`() {
        val id = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
        val current = record(id, 7, "fid-1", now.minusSeconds(60))
        val heartbeat = current.copy(updatedAt = now, lastSeenAt = now)
        val store = Mockito.mock(PushInstallationStore::class.java, org.mockito.stubbing.Answer { invocation ->
            when (invocation.method.name) {
                "ownerIdsForFid" -> listOf(7L)
                "installationIdsForFid" -> listOf(id)
                "findByFid" -> current
                "heartbeat" -> heartbeat
                else -> Answers.RETURNS_DEFAULTS.answer(invocation)
            }
        })

        val result = service(store).register(7, parseFid("fid-1"))

        assertFalse(result.created)
        assertEquals(id, result.installation.id)
        assertEquals(now, result.installation.lastSeenAt)
        Mockito.verify(store).heartbeat(id, 7, now)
    }

    @Test
    fun `register transfers an active FID before creating its new owner row`() {
        val oldId = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
        val newId = UUID.fromString("123e4567-e89b-12d3-a456-426614174001")
        val old = record(oldId, 7, "fid-1", now.minusSeconds(60))
        val created = record(newId, 8, "fid-1", now)
        val store = Mockito.mock(PushInstallationStore::class.java, org.mockito.stubbing.Answer { invocation ->
            when (invocation.method.name) {
                "ownerIdsForFid" -> listOf(7L)
                "installationIdsForFid" -> listOf(oldId)
                "findByFid" -> old
                "insert" -> created
                else -> Answers.RETURNS_DEFAULTS.answer(invocation)
            }
        })

        val result = service(store).register(8, parseFid("fid-1"))

        assertTrue(result.created)
        assertEquals(newId, result.installation.id)
        Mockito.verify(store).transfer(oldId, now)
        assertEquals(created, result.installation)
    }

    @Test
    fun `FID parser rejects whitespace-only credentials without trimming valid values`() {
        assertFailsWith<IllegalArgumentException> { parseFid(" \t\r\n") }
        assertEquals(" fid ", parseFid(" fid ").value)
    }

    @Test
    fun `register retries the whole transaction when the locked owner set changes`() {
        val oldId = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
        val newId = UUID.fromString("123e4567-e89b-12d3-a456-426614174001")
        val old = record(oldId, 7, "fid-race", now)
        val created = record(newId, 9, "fid-race", now)
        val store = Mockito.mock(PushInstallationStore::class.java)
        Mockito.`when`(store.ownerIdsForFid(parseFid("fid-race")))
            .thenReturn(listOf(7L), listOf(7L, 8L), listOf(7L, 8L))
        Mockito.`when`(store.installationIdsForFid(parseFid("fid-race")))
            .thenReturn(listOf(oldId))
        Mockito.`when`(store.findByFid(parseFid("fid-race")))
            .thenReturn(old)
        Mockito.`when`(
            store.insert(
                Mockito.any(UUID::class.java) ?: newId,
                Mockito.anyLong(),
                Mockito.any(PushFid::class.java) ?: parseFid("matcher"),
                Mockito.any(Instant::class.java) ?: now,
            ),
        ).thenReturn(created)

        val result = service(store).register(9, parseFid("fid-race"))

        assertEquals(newId, result.installation.id)
        Mockito.verify(store, Mockito.atLeast(3)).ownerIdsForFid(parseFid("fid-race"))
        Mockito.verify(store, Mockito.atLeastOnce()).lockUser(8L)
        Mockito.verify(store, Mockito.atLeastOnce()).lockUser(9L)
    }

    private fun service(store: PushInstallationStore) =
        PushInstallationService(store, ImmediateTransactionManager(), clock)

    private fun record(id: UUID, userId: Long, fid: String, timestamp: Instant) =
        PushInstallationRecord(
            id = id,
            userId = userId,
            fid = parseFid(fid),
            status = InstallationStatus.ACTIVE,
            registrationVersion = 1,
            createdAt = timestamp,
            updatedAt = timestamp,
            lastSeenAt = timestamp,
            terminalAt = null,
        )

    private class ImmediateTransactionManager : PlatformTransactionManager {
        override fun getTransaction(definition: TransactionDefinition?): TransactionStatus = SimpleTransactionStatus()
        override fun commit(status: TransactionStatus) = Unit
        override fun rollback(status: TransactionStatus) = Unit
    }
}
