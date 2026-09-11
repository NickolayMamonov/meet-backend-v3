package dev.whysoezzy.meet.service.push

import dev.whysoezzy.meet.config.PushRuntimeSettings
import mu.KotlinLogging
import org.springframework.context.annotation.Conditional
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component
import org.springframework.stereotype.Service
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import java.sql.ResultSet
import java.sql.Timestamp
import java.time.Clock
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.Collections
import java.util.LinkedHashMap
import java.util.UUID

private val dispatcherLogger = KotlinLogging.logger {}

/**
 * The only delivery boundary used by the scheduler and the diagnostic path.
 *
 * The Firebase adapter owns the SDK and maps its exceptions into these four
 * values. Keeping this type SDK-free is important: the transaction code never
 * needs to know which transport is in use.
 */
interface PushProvider {
    fun send(fid: PushFid, message: PushReminderMessage): PushDeliveryResult
}

class PushFid internal constructor(private val raw: String) {
    val value: String
        get() = raw
    internal fun rawValue(): String = raw
    override fun toString(): String = "PushFid(redacted)"
    override fun equals(other: Any?): Boolean = other is PushFid && raw == other.raw
    override fun hashCode(): Int = raw.hashCode()

    companion object {
        internal fun of(raw: String): PushFid = PushFid(raw)
    }
}

class PushReminderMessage(
    val title: String,
    val body: String,
    sourceData: Map<String, String>,
) {
    val data: Map<String, String> = Collections.unmodifiableMap(LinkedHashMap(sourceData))

    fun data(): Map<String, String> = data

    init {
        require(data.keys == REQUIRED_DATA_KEYS) { "Invalid reminder message shape" }
    }

    companion object {
        private val REQUIRED_DATA_KEYS = setOf(
            "eventType",
            "schemaVersion",
            "eventId",
            "meetingId",
            "reminderOffsetMinutes",
            "issuedAt",
            "destination",
        )

        fun meetingReminder(
            eventId: UUID,
            meetingId: Long,
            reminderOffsetMinutes: Int,
            issuedAt: Instant,
        ): PushReminderMessage {
            require(meetingId > 0)
            require(reminderOffsetMinutes == 60 || reminderOffsetMinutes == 1_440)
            val offsetText = reminderOffsetMinutes.toString()
            val period = if (reminderOffsetMinutes == 60) "1 hour" else "24 hours"
            return PushReminderMessage(
                title = "Meeting reminder",
                body = "A meeting you joined starts in $period.",
                sourceData = linkedMapOf(
                    "eventType" to "MEETING_REMINDER",
                    "schemaVersion" to "1",
                    "eventId" to eventId.toString(),
                    "meetingId" to meetingId.toString(),
                    "reminderOffsetMinutes" to offsetText,
                    "issuedAt" to issuedAt.truncatedTo(ChronoUnit.MILLIS).toString(),
                    "destination" to "MEETING_DETAILS",
                ),
            )
        }
    }
}

sealed interface PushDeliveryResult {
    data object Accepted : PushDeliveryResult
    data object InvalidRegistration : PushDeliveryResult
    data object TransientFailure : PushDeliveryResult
    data object Unavailable : PushDeliveryResult
}

enum class ReminderTargetStatus {
    PENDING,
    LEASED,
    RETRY_WAIT,
    SENT,
    INVALID,
    FAILED,
    SKIPPED,
}

data class ReminderLease(
    val targetId: UUID,
    val claimId: UUID,
    val userId: Long,
    val meetingId: Long,
    val installationId: UUID,
    val leaseToken: UUID,
    val attempt: Int,
    val leaseUntil: Instant,
)

data class PreparedReminderSend(
    val fid: PushFid,
    val registrationVersion: Long,
    val message: PushReminderMessage,
)

enum class ReminderSkipReason {
    USER_UNAVAILABLE,
    OPTED_OUT,
    LEFT_MEETING,
    MEETING_UNAVAILABLE,
    START_CHANGED,
    STARTED,
    INSTALLATION_UNAVAILABLE,
    INSTALLATION_STALE,
    DEADLINE_PASSED,
}

sealed interface ReminderFinalization {
    data object Accepted : ReminderFinalization
    data object InvalidRegistration : ReminderFinalization
    data object TransientFailure : ReminderFinalization
    data object Unavailable : ReminderFinalization
}

/**
 * Store contract for the dispatch side of V10. Implementations must keep all
 * SQL state transitions conditional on the lease token. In particular, a false
 * result means that a different worker/recovery transaction won and the caller
 * must not attempt any follow-up mutation.
 */
interface ReminderDispatchStore {
    fun leaseNext(): ReminderLease?
    fun prepareSend(lease: ReminderLease, now: Instant): PreparedReminderSend?
    fun skipIneligible(lease: ReminderLease, now: Instant): Boolean
    fun finalize(
        lease: ReminderLease,
        send: PreparedReminderSend,
        outcome: ReminderFinalization,
        now: Instant,
    ): Boolean

    fun recoverAndExpire(limit: Int, now: Instant): Int
}

@Service
@Conditional(DispatchPushCondition::class)
class ReminderDispatcher(
    private val store: ReminderDispatchStore,
    private val provider: PushProvider,
    transactionManager: PlatformTransactionManager,
    private val clock: Clock,
) {
    private val transaction = TransactionTemplate(transactionManager).apply {
        timeout = TRANSACTION_TIMEOUT_SECONDS
    }

    /**
     * One invocation leases at most one target and never owns an executor
     * slot beyond the synchronous provider call and its finalization.
     */
    fun dispatchOne() {
        val lease = transaction.execute { store.leaseNext() } ?: return
        val now = clock.instant()
        val prepared = transaction.execute { store.prepareSend(lease, now) }
        if (prepared == null) {
            transaction.execute { store.skipIneligible(lease, clock.instant()) }
            return
        }

        val outcome = try {
            when (provider.send(prepared.fid, prepared.message)) {
                PushDeliveryResult.Accepted -> ReminderFinalization.Accepted
                PushDeliveryResult.InvalidRegistration -> ReminderFinalization.InvalidRegistration
                PushDeliveryResult.TransientFailure -> ReminderFinalization.TransientFailure
                PushDeliveryResult.Unavailable -> ReminderFinalization.Unavailable
            }
        } catch (exception: Exception) {
            // A provider implementation should normalize failures. This guard
            // protects lease recovery if an adapter or test double violates it.
            dispatcherLogger.warn { "push dispatch provider failure category=${exception::class.simpleName}" }
            ReminderFinalization.Unavailable
        }

        transaction.execute {
            store.finalize(lease, prepared, outcome, clock.instant())
        }
    }

    companion object {
        private const val TRANSACTION_TIMEOUT_SECONDS = 5
    }
}

/**
 * Shared condition helpers keep default-disabled applications free of store
 * and provider beans (and therefore free of credential initialization).
 */
class DispatchPushCondition : org.springframework.context.annotation.Condition {
    override fun matches(
        context: org.springframework.context.annotation.ConditionContext,
        metadata: org.springframework.core.type.AnnotatedTypeMetadata,
    ): Boolean =
        context.environment.getProperty("app.push.dispatch-enabled", Boolean::class.java, false) &&
            context.environment.getProperty("app.push.provider-enabled", Boolean::class.java, false)
}

class MaintenancePushCondition : org.springframework.context.annotation.Condition {
    override fun matches(
        context: org.springframework.context.annotation.ConditionContext,
        metadata: org.springframework.core.type.AnnotatedTypeMetadata,
    ): Boolean {
        val enabled = context.environment.getProperty("app.push.maintenance-enabled", Boolean::class.java, false)
        val discovery = context.environment.getProperty("app.push.discovery-enabled", Boolean::class.java, false)
        val dispatch = context.environment.getProperty("app.push.dispatch-enabled", Boolean::class.java, false)
        return enabled || discovery || dispatch
    }
}

class DiagnosticPushCondition : org.springframework.context.annotation.Condition {
    override fun matches(
        context: org.springframework.context.annotation.ConditionContext,
        metadata: org.springframework.core.type.AnnotatedTypeMetadata,
    ): Boolean =
        context.environment.getProperty("app.push.diagnostic-enabled", Boolean::class.java, false) &&
            context.environment.getProperty("app.push.provider-enabled", Boolean::class.java, false)
}

/**
 * JDBC implementation for the dispatch contract. The lease, preparation and
 * completion methods are intentionally small transaction units; the caller
 * owns their TransactionTemplate so a provider call can never execute while a
 * transaction is open.
 */
@Component
class JdbcReminderDispatchStore(
    private val jdbc: JdbcTemplate,
) : ReminderDispatchStore {
    override fun leaseNext(): ReminderLease? {
        setLockTimeout()
        val token = UUID.randomUUID()
        return jdbc.query(
            """
            WITH candidate AS (
                SELECT id
                FROM meeting_reminder_targets
                WHERE (
                    status IN ('PENDING', 'RETRY_WAIT')
                    AND next_attempt_at <= clock_timestamp()
                    AND attempts < ?
                ) OR (
                    status = 'LEASED'
                    AND lease_until <= clock_timestamp()
                    AND attempts < ?
                )
                ORDER BY next_attempt_at NULLS FIRST, id
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            )
            UPDATE meeting_reminder_targets t
            SET status = 'LEASED',
                attempts = t.attempts + 1,
                lease_token = ?,
                lease_until = clock_timestamp() + INTERVAL '10 minutes',
                reason = NULL,
                completed_at = NULL
            FROM candidate c
            WHERE t.id = c.id
            RETURNING t.id, t.claim_id, t.user_id, t.installation_id,
                      t.attempts, t.lease_token, t.lease_until,
                      (SELECT meeting_id FROM meeting_reminder_claims WHERE id = t.claim_id) AS meeting_id
            """.trimIndent(),
            ::mapLease,
            PushRuntimeSettings.MAX_ATTEMPTS,
            PushRuntimeSettings.MAX_ATTEMPTS,
            token,
        ).firstOrNull()
    }

    override fun prepareSend(lease: ReminderLease, now: Instant): PreparedReminderSend? {
        setLockTimeout()
        val row = load(lease) ?: return null
        val eligibility = eligibility(row, now)
        if (eligibility != null) return null
        return PreparedReminderSend(
            fid = parseFid(requireNotNull(row.fid)),
            registrationVersion = row.registrationVersion,
            message = ReminderMessageFactory.create(
                eventId = row.claimId,
                meetingId = row.meetingId,
                offset = ReminderOffset.fromMinutes(row.offsetMinutes),
                issuedAt = row.issuedAt,
            ),
        )
    }

    override fun skipIneligible(lease: ReminderLease, now: Instant): Boolean {
        setLockTimeout()
        lockCompletionRows(lease)
        val row = load(lease) ?: return false
        val reason = eligibility(row, now) ?: return false
        val changed = jdbc.update(
            """
            UPDATE meeting_reminder_targets
            SET status = 'SKIPPED', reason = ?, lease_token = NULL,
                lease_until = NULL, completed_at = ?
            WHERE id = ? AND lease_token = ? AND status = 'LEASED'
              AND lease_until > clock_timestamp()
            """.trimIndent(),
            reason.name,
            timestamp(now),
            lease.targetId,
            lease.leaseToken,
        ) > 0
        if (changed) reduceClaim(lease.claimId, now)
        return changed
    }

    override fun finalize(
        lease: ReminderLease,
        send: PreparedReminderSend,
        outcome: ReminderFinalization,
        now: Instant,
    ): Boolean {
        setLockTimeout()
        // Explicit lock order: user -> claim -> target -> installation.
        jdbc.queryForList("SELECT id FROM users WHERE id = ? FOR UPDATE", Long::class.java, lease.userId)
        jdbc.queryForList("SELECT id FROM meeting_reminder_claims WHERE id = ? FOR UPDATE", UUID::class.java, lease.claimId)
        jdbc.queryForList(
            "SELECT id FROM meeting_reminder_targets WHERE id = ? FOR UPDATE",
            UUID::class.java,
            lease.targetId,
        )
        jdbc.queryForList(
            "SELECT id FROM push_installations WHERE id = ? FOR UPDATE",
            UUID::class.java,
            lease.installationId,
        )

        val row = load(lease) ?: return false
        if (row.fid != send.fid.value || row.registrationVersion != send.registrationVersion) return false
        val reason = eligibility(row, now)
        val decision = decision(lease, outcome, row, reason, send, now)
        val changed = jdbc.update(
            """
            UPDATE meeting_reminder_targets
            SET status = ?, reason = ?, next_attempt_at = ?,
                lease_token = NULL, lease_until = NULL, completed_at = ?
            WHERE id = ? AND lease_token = ? AND status = 'LEASED'
              AND lease_until > clock_timestamp()
            """.trimIndent(),
            decision.status,
            decision.reason,
            decision.nextAttemptAt?.let(::timestamp) ?: timestamp(now),
            timestamp(now).takeIf { decision.status in TERMINAL_TARGETS },
            lease.targetId,
            lease.leaseToken,
        ) > 0
        if (changed) reduceClaim(lease.claimId, now)
        return changed
    }

    override fun recoverAndExpire(limit: Int, now: Instant): Int {
        require(limit > 0)
        setLockTimeout()
        val expiredInstallations = expireStaleInstallations(limit, now)
        val candidates = jdbc.query(
            """
            SELECT id, claim_id, user_id, installation_id, lease_token, attempts, lease_until,
                   (SELECT meeting_id FROM meeting_reminder_claims WHERE id = claim_id) AS meeting_id
            FROM meeting_reminder_targets
            WHERE status = 'LEASED' AND attempts >= ? AND lease_until <= clock_timestamp()
            ORDER BY lease_until, id LIMIT ?
            """.trimIndent(),
            { rs, _ ->
                ReminderLease(
                    targetId = rs.getObject("id", UUID::class.java),
                    claimId = rs.getObject("claim_id", UUID::class.java),
                    userId = rs.getLong("user_id"),
                    meetingId = rs.getLong("meeting_id"),
                    installationId = rs.getObject("installation_id", UUID::class.java),
                    leaseToken = rs.getObject("lease_token", UUID::class.java),
                    attempt = rs.getInt("attempts"),
                    leaseUntil = rs.getTimestamp("lease_until").toInstant(),
                )
            },
            PushRuntimeSettings.MAX_ATTEMPTS,
            limit,
        )
        var recovered = 0
        candidates.forEach { lease ->
            jdbc.queryForList("SELECT id FROM users WHERE id = ? FOR UPDATE", Long::class.java, lease.userId)
            jdbc.queryForList("SELECT id FROM meeting_reminder_claims WHERE id = ? FOR UPDATE", UUID::class.java, lease.claimId)
            jdbc.queryForList("SELECT id FROM meeting_reminder_targets WHERE id = ? FOR UPDATE", UUID::class.java, lease.targetId)
            val row = load(lease, requireLiveLease = false)
            val skipReason = row?.let { eligibility(it, now) }
            val status = if (skipReason == null) "FAILED" else "SKIPPED"
            val reason = skipReason?.name ?: "ATTEMPTS_EXHAUSTED"
            if (
                row != null &&
                jdbc.update(
                    """
                    UPDATE meeting_reminder_targets
                    SET status = ?, reason = ?,
                        lease_token = NULL, lease_until = NULL, completed_at = ?
                    WHERE id = ? AND lease_token = ? AND status = 'LEASED' AND attempts >= ?
                      AND lease_until <= clock_timestamp()
                    """.trimIndent(),
                    status,
                    reason,
                    timestamp(now),
                    lease.targetId,
                    lease.leaseToken,
                    PushRuntimeSettings.MAX_ATTEMPTS,
                ) > 0
            ) {
                recovered++
                reduceClaim(lease.claimId, now)
            }
        }
        return recovered + expiredInstallations
    }

    private fun load(lease: ReminderLease, requireLiveLease: Boolean = true): DispatchRow? =
        jdbc.query(
            """
            SELECT t.id, t.claim_id, t.user_id, t.installation_id, t.lease_token,
                   t.status AS target_status, t.attempts,
                   c.meeting_id, c.reminder_offset_minutes, c.meeting_start_ms,
                   c.start_version, c.deadline_at, c.issued_at,
                   u.deleted_at, u.notifications_enabled,
                   m.status AS meeting_status, m.time AS actual_start_ms,
                   m.push_start_version AS actual_start_version,
                   EXISTS (
                       SELECT 1 FROM meeting_participants mp
                       WHERE mp.user_id = t.user_id AND mp.meeting_id = c.meeting_id
                   ) AS joined,
                   i.fid, i.status AS installation_status,
                   i.registration_version, i.last_seen_at
            FROM meeting_reminder_targets t
            JOIN meeting_reminder_claims c ON c.id = t.claim_id
            JOIN users u ON u.id = t.user_id
            JOIN meetings m ON m.id = c.meeting_id
            JOIN push_installations i ON i.id = t.installation_id
            WHERE t.id = ? AND t.lease_token = ? AND t.status = 'LEASED'
              ${if (requireLiveLease) "AND t.lease_until > clock_timestamp()" else ""}
            """.trimIndent(),
            ::mapRow,
            lease.targetId,
            lease.leaseToken,
        ).firstOrNull()

    private fun eligibility(row: DispatchRow, now: Instant): ReminderEligibilityReason? =
        ReminderEligibility.reason(
            ReminderEligibilityInput(
                userAvailable = row.deletedAt == null,
                optedIn = row.notificationsEnabled,
                joinedMeeting = row.joined,
                meetingAvailable = row.meetingStatus == "ACTIVE",
                expectedStart = Instant.ofEpochMilli(row.meetingStartMs),
                actualStart = Instant.ofEpochMilli(row.actualStartMs),
                expectedStartVersion = row.startVersion,
                actualStartVersion = row.actualStartVersion,
                installationAvailable = row.installationStatus == "ACTIVE" && row.fid != null,
                installationFresh = row.lastSeenAt.isAfter(now.minus(PushRuntimeSettings.STALENESS_DAYS, ChronoUnit.DAYS)),
                now = now,
                deadline = row.deadlineAt,
            ),
        )

    private fun decision(
        lease: ReminderLease,
        outcome: ReminderFinalization,
        row: DispatchRow,
        ineligible: ReminderEligibilityReason?,
        send: PreparedReminderSend,
        now: Instant,
    ): TargetDecision {
        if (ineligible != null) {
            return TargetDecision("SKIPPED", ineligible.name, null)
        }
        if (outcome == ReminderFinalization.InvalidRegistration) {
            jdbc.update(
                """
                UPDATE push_installations
                SET fid = NULL, status = 'UNREGISTERED', registration_version = registration_version + 1,
                    updated_at = ?, terminal_at = ?
                WHERE id = ? AND user_id = ? AND status = 'ACTIVE'
                  AND registration_version = ? AND fid = ?
                """.trimIndent(),
                timestamp(now), timestamp(now), lease.installationId, lease.userId,
                send.registrationVersion, send.fid.value,
            )
            return TargetDecision("INVALID", "UNREGISTERED", null)
        }
        return when (outcome) {
            ReminderFinalization.Accepted -> TargetDecision("SENT", "ACCEPTED", null)
            ReminderFinalization.InvalidRegistration -> error("unreachable")
            ReminderFinalization.TransientFailure,
            ReminderFinalization.Unavailable -> {
                if (lease.attempt >= PushRuntimeSettings.MAX_ATTEMPTS) {
                    TargetDecision("FAILED", "ATTEMPTS_EXHAUSTED", null)
                } else {
                    val next = ReminderRetryPolicy.nextAttemptAt(
                        lease.targetId,
                        lease.attempt,
                        now,
                        row.deadlineAt,
                        Instant.ofEpochMilli(row.meetingStartMs),
                    )
                    if (next == null) {
                        TargetDecision("FAILED", "ATTEMPTS_EXHAUSTED", null)
                    } else {
                        TargetDecision(
                            "RETRY_WAIT",
                            if (outcome == ReminderFinalization.TransientFailure) "TRANSIENT" else "PROVIDER_UNAVAILABLE",
                            next,
                        )
                    }
                }
            }
        }
    }

    private fun reduceClaim(claimId: UUID, now: Instant) {
        val state = jdbc.queryForObject(
            """
            SELECT
              bool_or(status IN ('PENDING', 'LEASED', 'RETRY_WAIT')) AS pending,
              bool_or(status = 'SENT') AS sent,
              bool_or(status IN ('INVALID', 'FAILED')) AS failed
            FROM meeting_reminder_targets WHERE claim_id = ?
            """.trimIndent(),
            { rs, _ ->
                Triple(
                    rs.getBoolean("pending"),
                    rs.getBoolean("sent"),
                    rs.getBoolean("failed"),
                )
            },
            claimId,
        ) ?: return
        if (state.first) return
        val status = when {
            state.second -> "SENT"
            state.third -> "FAILED"
            else -> "SKIPPED"
        }
        jdbc.update(
            "UPDATE meeting_reminder_claims SET status = ?, completed_at = ? WHERE id = ? AND status = 'PENDING'",
            status,
            timestamp(now),
            claimId,
        )
    }

    private fun mapLease(rs: ResultSet, rowNum: Int): ReminderLease =
        ReminderLease(
            targetId = rs.getObject("id", UUID::class.java),
            claimId = rs.getObject("claim_id", UUID::class.java),
            userId = rs.getLong("user_id"),
            meetingId = rs.getLong("meeting_id"),
            installationId = rs.getObject("installation_id", UUID::class.java),
            leaseToken = rs.getObject("lease_token", UUID::class.java),
            attempt = rs.getInt("attempts"),
            leaseUntil = rs.getTimestamp("lease_until").toInstant(),
        )

    private fun mapRow(rs: ResultSet, rowNum: Int): DispatchRow =
        DispatchRow(
            claimId = rs.getObject("claim_id", UUID::class.java),
            meetingId = rs.getLong("meeting_id"),
            offsetMinutes = rs.getInt("reminder_offset_minutes"),
            meetingStartMs = rs.getLong("meeting_start_ms"),
            startVersion = rs.getLong("start_version"),
            deadlineAt = rs.getTimestamp("deadline_at").toInstant(),
            issuedAt = rs.getTimestamp("issued_at").toInstant(),
            deletedAt = rs.getTimestamp("deleted_at")?.toInstant(),
            notificationsEnabled = rs.getBoolean("notifications_enabled"),
            meetingStatus = rs.getString("meeting_status"),
            actualStartMs = rs.getLong("actual_start_ms"),
            actualStartVersion = rs.getLong("actual_start_version"),
            joined = rs.getBoolean("joined"),
            fid = rs.getString("fid"),
            installationStatus = rs.getString("installation_status"),
            registrationVersion = rs.getLong("registration_version"),
            lastSeenAt = rs.getTimestamp("last_seen_at").toInstant(),
        )

    private data class DispatchRow(
        val claimId: UUID,
        val meetingId: Long,
        val offsetMinutes: Int,
        val meetingStartMs: Long,
        val startVersion: Long,
        val deadlineAt: Instant,
        val issuedAt: Instant,
        val deletedAt: Instant?,
        val notificationsEnabled: Boolean,
        val meetingStatus: String,
        val actualStartMs: Long,
        val actualStartVersion: Long,
        val joined: Boolean,
        val fid: String?,
        val installationStatus: String,
        val registrationVersion: Long,
        val lastSeenAt: Instant,
    )

    private data class TargetDecision(
        val status: String,
        val reason: String,
        val nextAttemptAt: Instant?,
    )

    private companion object {
        val TERMINAL_TARGETS = setOf("SENT", "INVALID", "FAILED", "SKIPPED")
        fun timestamp(value: Instant): Timestamp = Timestamp.from(value)
    }

    private fun setLockTimeout() {
        jdbc.execute("SET LOCAL lock_timeout = '2s'")
    }

    private fun expireStaleInstallations(limit: Int, now: Instant): Int {
        val candidates = jdbc.query(
            """
            SELECT id, user_id
            FROM push_installations
            WHERE status = 'ACTIVE'
              AND last_seen_at <= clock_timestamp() - INTERVAL '35 days'
            ORDER BY last_seen_at, id
            LIMIT ?
            """.trimIndent(),
            { rs, _ -> rs.getObject("id", UUID::class.java) to rs.getLong("user_id") },
            limit,
        )
        var expired = 0
        candidates.forEach { (installationId, userId) ->
            jdbc.queryForList("SELECT id FROM users WHERE id = ? FOR UPDATE", Long::class.java, userId)
            jdbc.queryForList(
                "SELECT id FROM push_installations WHERE id = ? FOR UPDATE",
                UUID::class.java,
                installationId,
            )
            expired += jdbc.update(
                """
                UPDATE push_installations
                SET fid = NULL, status = 'EXPIRED',
                    registration_version = registration_version + 1,
                    updated_at = ?, terminal_at = ?
                WHERE id = ? AND user_id = ? AND status = 'ACTIVE'
                  AND last_seen_at <= clock_timestamp() - INTERVAL '35 days'
                """.trimIndent(),
                timestamp(now),
                timestamp(now),
                installationId,
                userId,
            )
        }
        return expired
    }

    private fun lockCompletionRows(lease: ReminderLease) {
        jdbc.queryForList("SELECT id FROM users WHERE id = ? FOR UPDATE", Long::class.java, lease.userId)
        jdbc.queryForList("SELECT id FROM meeting_reminder_claims WHERE id = ? FOR UPDATE", UUID::class.java, lease.claimId)
        jdbc.queryForList("SELECT id FROM meeting_reminder_targets WHERE id = ? FOR UPDATE", UUID::class.java, lease.targetId)
        jdbc.queryForList("SELECT id FROM push_installations WHERE id = ? FOR UPDATE", UUID::class.java, lease.installationId)
    }
}
