package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.controller.PushInstallationController
import dev.whysoezzy.meet.api.dto.PushInstallationRequest
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.security.AuthUtils
import dev.whysoezzy.meet.service.push.InstallationStatus
import dev.whysoezzy.meet.service.push.PushInstallationMutation
import dev.whysoezzy.meet.service.push.PushInstallationRecord
import dev.whysoezzy.meet.service.push.PushInstallationService
import dev.whysoezzy.meet.service.push.parseFid
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class PushInstallationControllerMvcTest {
    private val auth = Mockito.mock(AuthUtils::class.java)
    private val installationId = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
    private val seenAt = Instant.parse("2026-09-11T20:00:00Z")

    @Test
    fun `register maps created and heartbeat mutations to the documented HTTP statuses`() {
        Mockito.`when`(auth.getCurrentUserId()).thenReturn(7L)
        val active = record(installationId, 7L)
        val service = StubService(active)
        val controller = PushInstallationController(service, auth)

        val created = controller.register(PushInstallationRequest("fid-1"))
        assertEquals(201, created.statusCode.value())
        assertEquals(installationId, created.body!!.installationId)
        assertEquals("ACTIVE", created.body!!.status)
        assertEquals(200, controller.register(PushInstallationRequest("fid-1")).statusCode.value())
        Mockito.verify(auth, Mockito.times(2)).getCurrentUserId()
    }

    @Test
    fun `rotate and unregister enforce the canonical UUID boundary and map successful calls`() {
        Mockito.`when`(auth.getCurrentUserId()).thenReturn(7L)
        val service = StubService(record(installationId, 7L))
        val controller = PushInstallationController(service, auth)

        val rotated = controller.rotate(installationId.toString(), PushInstallationRequest("fid-2"))
        assertEquals(installationId, rotated.installationId)
        controller.unregister(installationId.toString())
        assertEquals(1, service.unregisterCalls)
        assertFailsWith<BadRequestException> {
            controller.rotate(installationId.toString().uppercase(), PushInstallationRequest("fid-2"))
        }
        assertFailsWith<BadRequestException> { controller.unregister("not-a-uuid") }
    }

    private fun record(id: UUID, userId: Long) = PushInstallationRecord(
        id = id,
        userId = userId,
        fid = parseFid("fid-1"),
        status = InstallationStatus.ACTIVE,
        registrationVersion = 1,
        createdAt = seenAt,
        updatedAt = seenAt,
        lastSeenAt = seenAt,
        terminalAt = null,
    )

    private class StubService(
        private val installation: PushInstallationRecord,
    ) : PushInstallationService(
        Mockito.mock(dev.whysoezzy.meet.service.push.PushInstallationStore::class.java),
        ImmediateTransactionManager(),
        java.time.Clock.systemUTC(),
    ) {
        private var registrations = 0
        var unregisterCalls = 0

        override fun register(userId: Long, fid: dev.whysoezzy.meet.service.push.PushFid): PushInstallationMutation =
            PushInstallationMutation(installation, created = registrations++ == 0)

        override fun rotate(
            userId: Long,
            installationId: UUID,
            fid: dev.whysoezzy.meet.service.push.PushFid,
        ): PushInstallationMutation = PushInstallationMutation(installation)

        override fun unregister(userId: Long, installationId: UUID) {
            unregisterCalls++
        }
    }

    private class ImmediateTransactionManager : org.springframework.transaction.PlatformTransactionManager {
        override fun getTransaction(
            definition: org.springframework.transaction.TransactionDefinition?,
        ): org.springframework.transaction.TransactionStatus =
            org.springframework.transaction.support.SimpleTransactionStatus()

        override fun commit(status: org.springframework.transaction.TransactionStatus) = Unit
        override fun rollback(status: org.springframework.transaction.TransactionStatus) = Unit
    }
}
