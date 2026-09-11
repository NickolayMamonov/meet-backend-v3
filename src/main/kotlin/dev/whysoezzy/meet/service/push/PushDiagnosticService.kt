package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.api.error.ApiException
import dev.whysoezzy.meet.api.error.BadRequestException
import dev.whysoezzy.meet.api.error.NotFoundException
import org.springframework.context.annotation.Conditional
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.time.Clock
import java.time.Instant
import java.sql.Timestamp
import java.util.UUID
import java.util.concurrent.Semaphore

data class PushDiagnosticCommand(
    val userId: Long,
    val installationId: UUID,
    val meetingId: Long,
    val reminderOffsetMinutes: Int,
    val mode: PushDiagnosticMode,
)

enum class PushDiagnosticMode {
    SINGLE,
    DEDUP_PAIR,
}

data class DiagnosticSelection(
    val userId: Long,
    val installationId: UUID,
    val meetingId: Long,
    val fid: PushFid,
    val registrationVersion: Long,
)

enum class DiagnosticInvalidation {
    APPLIED,
    ALREADY_CHANGED,
    FAILED,
}

interface PushDiagnosticStore {
    /**
     * This query applies owner, deletion, opt-in, membership, meeting state,
     * future-start, installation status, and freshness predicates. It
     * intentionally does not apply the ordinary reminder due window.
     */
    fun selectEligible(command: PushDiagnosticCommand, now: Instant): DiagnosticSelection?

    fun recheckEligible(selection: DiagnosticSelection, now: Instant): DiagnosticSelection?

    fun invalidateExact(
        selection: DiagnosticSelection,
        expectedFid: PushFid,
        expectedRegistrationVersion: Long,
    ): DiagnosticInvalidation
}

enum class DiagnosticCallResult {
    Accepted,
    InvalidTarget,
    RetryableFailure,
    ProviderUnavailable,
    NotAttempted,
}

sealed interface PushDiagnosticResponse {
    data class Single(val result: DiagnosticCallResult) : PushDiagnosticResponse
    data class Pair(
        val result: DiagnosticAggregateResult,
        val first: DiagnosticCallResult,
        val second: DiagnosticCallResult,
    ) : PushDiagnosticResponse
}

enum class DiagnosticAggregateResult {
    ACCEPTED,
    ACCEPTED_PAIR,
    INVALID_TARGET,
    RETRYABLE_FAILURE,
    PROVIDER_UNAVAILABLE,
    INCONCLUSIVE,
}

@Service
@Conditional(DiagnosticPushCondition::class)
class PushDiagnosticService(
    private val store: PushDiagnosticStore,
    private val provider: PushProvider,
    transactionManager: PlatformTransactionManager,
    private val clock: Clock,
) {
    private val transaction = TransactionTemplate(transactionManager).apply {
        timeout = TRANSACTION_TIMEOUT_SECONDS
    }
    private val permit = Semaphore(1)

    fun send(command: PushDiagnosticCommand): PushDiagnosticResponse {
        validate(command)
        if (!permit.tryAcquire()) {
            throw unavailable()
        }

        try {
            val selected = try {
                transaction.execute {
                    store.selectEligible(command, clock.instant())
                }
            } catch (exception: ApiException) {
                throw exception
            } catch (_: RuntimeException) {
                throw unavailable()
            } ?: throw NotFoundException("Push diagnostic target not found")

            val message = PushReminderMessage.meetingReminder(
                eventId = UUID.randomUUID(),
                meetingId = command.meetingId,
                reminderOffsetMinutes = command.reminderOffsetMinutes,
                issuedAt = clock.instant(),
            )

            val first = call(selected, message)
            val firstInvalidation = if (first.result == DiagnosticCallResult.InvalidTarget) {
                invalidate(selected, first.sentFid)
            } else {
                InvalidationOutcome.CONTINUE
            }
            if (command.mode == PushDiagnosticMode.SINGLE) {
                if (firstInvalidation == InvalidationOutcome.FAILED) throw unavailable()
                return PushDiagnosticResponse.Single(first.result)
            }

            if (firstInvalidation != InvalidationOutcome.CONTINUE) {
                return PushDiagnosticResponse.Pair(
                    result = DiagnosticAggregateResult.INCONCLUSIVE,
                    first = first.result,
                    second = DiagnosticCallResult.NotAttempted,
                )
            }

            val secondTarget = try {
                transaction.execute {
                    store.recheckEligible(selected, clock.instant())
                }
            } catch (_: RuntimeException) {
                throw unavailable()
            }
            if (secondTarget == null) {
                return PushDiagnosticResponse.Pair(
                    result = DiagnosticAggregateResult.INCONCLUSIVE,
                    first = first.result,
                    second = DiagnosticCallResult.NotAttempted,
                )
            }
            if (
                secondTarget.fid.value != selected.fid.value ||
                secondTarget.registrationVersion != selected.registrationVersion
            ) {
                return PushDiagnosticResponse.Pair(
                    result = DiagnosticAggregateResult.INCONCLUSIVE,
                    first = first.result,
                    second = DiagnosticCallResult.NotAttempted,
                )
            }

            // The same immutable message object is deliberately reused. The
            // pair proves Android deduplication against a byte-identical event.
            val second = call(secondTarget, message)
            if (second.result == DiagnosticCallResult.InvalidTarget) {
                val invalidation = invalidate(secondTarget, second.sentFid)
                if (invalidation == InvalidationOutcome.FAILED) {
                    return PushDiagnosticResponse.Pair(
                        result = DiagnosticAggregateResult.INCONCLUSIVE,
                        first = first.result,
                        second = second.result,
                    )
                }
            }

            return PushDiagnosticResponse.Pair(
                result = if (
                    first.result == DiagnosticCallResult.Accepted &&
                    second.result == DiagnosticCallResult.Accepted
                ) {
                    DiagnosticAggregateResult.ACCEPTED_PAIR
                } else {
                    DiagnosticAggregateResult.INCONCLUSIVE
                },
                first = first.result,
                second = second.result,
            )
        } finally {
            permit.release()
        }
        error("Diagnostic operation did not produce a response")
    }

    private fun call(
        selection: DiagnosticSelection,
        message: PushReminderMessage,
    ): ProviderCall {
        return try {
            val result = when (provider.send(selection.fid, message)) {
                PushDeliveryResult.Accepted -> DiagnosticCallResult.Accepted
                PushDeliveryResult.InvalidRegistration -> DiagnosticCallResult.InvalidTarget
                PushDeliveryResult.TransientFailure -> DiagnosticCallResult.RetryableFailure
                PushDeliveryResult.Unavailable -> DiagnosticCallResult.ProviderUnavailable
            }
            ProviderCall(result, selection.fid, selection.registrationVersion)
        } catch (_: Exception) {
            ProviderCall(
                DiagnosticCallResult.ProviderUnavailable,
                selection.fid,
                selection.registrationVersion,
            )
        }
    }

    private fun invalidate(
        selection: DiagnosticSelection,
        sentFid: PushFid,
    ): InvalidationOutcome {
        return try {
            when (transaction.execute {
                store.invalidateExact(
                    selection = selection,
                    expectedFid = sentFid,
                    expectedRegistrationVersion = selection.registrationVersion,
                )
            } ?: throw unavailable()) {
                DiagnosticInvalidation.APPLIED -> InvalidationOutcome.CONTINUE
                DiagnosticInvalidation.ALREADY_CHANGED -> InvalidationOutcome.STOP
                DiagnosticInvalidation.FAILED -> InvalidationOutcome.FAILED
            }
        } catch (exception: ApiException) {
            throw exception
        } catch (_: RuntimeException) {
            throw unavailable()
        }
    }

    private fun validate(command: PushDiagnosticCommand) {
        if (command.userId <= 0 || command.meetingId <= 0) {
            throw BadRequestException("Invalid diagnostic target")
        }
        if (command.reminderOffsetMinutes != 60 && command.reminderOffsetMinutes != 1_440) {
            throw BadRequestException("Invalid reminder offset")
        }
    }

    private fun unavailable() =
        ApiException(HttpStatus.SERVICE_UNAVAILABLE, "PUSH_UNAVAILABLE", "Push delivery is unavailable")

    private enum class InvalidationOutcome {
        CONTINUE,
        STOP,
        FAILED,
    }

    private data class ProviderCall(
        val result: DiagnosticCallResult,
        val sentFid: PushFid,
        val registrationVersion: Long,
    )

    private companion object {
        const val TRANSACTION_TIMEOUT_SECONDS = 5
    }
}

@Component
class JdbcPushDiagnosticStore(
    private val jdbc: JdbcTemplate,
) : PushDiagnosticStore {
    override fun selectEligible(
        command: PushDiagnosticCommand,
        now: Instant,
    ): DiagnosticSelection? =
        query(command.userId, command.installationId, command.meetingId, now)

    override fun recheckEligible(
        selection: DiagnosticSelection,
        now: Instant,
    ): DiagnosticSelection? =
        query(selection.userId, selection.installationId, selection.meetingId, now)

    override fun invalidateExact(
        selection: DiagnosticSelection,
        expectedFid: PushFid,
        expectedRegistrationVersion: Long,
    ): DiagnosticInvalidation {
        return try {
            val changed = jdbc.update(
                """
                UPDATE push_installations
                SET fid = NULL, status = 'UNREGISTERED',
                    registration_version = registration_version + 1,
                    updated_at = clock_timestamp(), terminal_at = clock_timestamp()
                WHERE id = ? AND user_id = ? AND status = 'ACTIVE'
                  AND registration_version = ? AND fid = ?
                """.trimIndent(),
                selection.installationId,
                selection.userId,
                expectedRegistrationVersion,
                expectedFid.value,
            )
            if (changed > 0) DiagnosticInvalidation.APPLIED
            else DiagnosticInvalidation.ALREADY_CHANGED
        } catch (_: RuntimeException) {
            DiagnosticInvalidation.FAILED
        }
    }

    private fun query(
        userId: Long,
        installationId: UUID,
        meetingId: Long,
        now: Instant,
    ): DiagnosticSelection? =
        jdbc.query(
            """
            SELECT i.fid, i.registration_version
            FROM users u
            JOIN meeting_participants p ON p.user_id = u.id AND p.meeting_id = ?
            JOIN meetings m ON m.id = p.meeting_id
            JOIN push_installations i ON i.id = ?
            WHERE u.id = ? AND u.deleted_at IS NULL AND u.notifications_enabled
              AND m.id = ? AND m.status = 'ACTIVE'
              AND m.time > EXTRACT(EPOCH FROM ?::timestamptz) * 1000
              AND i.user_id = u.id AND i.status = 'ACTIVE' AND i.fid IS NOT NULL
              AND i.last_seen_at > ?::timestamptz - INTERVAL '35 days'
            """.trimIndent(),
            { rs, _ ->
                DiagnosticSelection(
                    userId = userId,
                    installationId = installationId,
                    meetingId = meetingId,
                    fid = parseFid(rs.getString("fid")),
                    registrationVersion = rs.getLong("registration_version"),
                )
            },
            meetingId,
            installationId,
            userId,
            meetingId,
            Timestamp.from(now),
            Timestamp.from(now),
        ).firstOrNull()
}
