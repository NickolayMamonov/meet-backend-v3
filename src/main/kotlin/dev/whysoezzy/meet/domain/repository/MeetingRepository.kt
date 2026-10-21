package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import org.springframework.data.domain.Pageable
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import org.springframework.stereotype.Repository
import jakarta.persistence.LockModeType
import org.springframework.data.jpa.repository.Lock

@Repository
interface MeetingRepository : JpaRepository<Meeting, Long> {
    fun findAllByDemoCatalogKeyIn(keys: Collection<String>): List<Meeting>

    fun findTop501BySourceAndSourceExternalIdNotNullOrderByIdAsc(source: EventSource): List<Meeting>

    fun findAllBySourceAndSourceExternalIdIn(source: EventSource, sourceExternalIds: Collection<String>): List<Meeting>

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    fun findForUpdateBySourceAndSourceExternalId(source: EventSource, sourceExternalId: String): Meeting?

    @Query(
        """
        SELECT m FROM Meeting m
        WHERE m.status = :status
          AND COALESCE(m.endsAt, m.time) >= :now
          AND function('timepad_policy_visible', m.id, :now) = true
        ORDER BY m.time ASC, m.id ASC
        """,
    )
    fun findDiscoveryMeetings(
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        WHERE m.status = :status
          AND COALESCE(m.endsAt, m.time) >= :now
          AND function('timepad_policy_visible', m.id, :now) = true
          AND m.id NOT IN :excludedIds
        ORDER BY m.time ASC, m.id ASC
        """,
    )
    fun findDiscoveryMeetingsExcluding(
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        @Param("excludedIds") excludedIds: Collection<Long>,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        JOIN m.tags t
        WHERE m.status = :status
          AND t.id = :tagId
          AND COALESCE(m.endsAt, m.time) >= :now
          AND function('timepad_policy_visible', m.id, :now) = true
        ORDER BY m.time ASC, m.id ASC
        """,
    )
    fun findDiscoveryMeetingsByTag(
        @Param("tagId") tagId: Long,
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        WHERE m.status = :status
          AND COALESCE(m.endsAt, m.time) >= :now
          AND function('timepad_policy_visible', m.id, :now) = true
          AND (
            LOWER(m.title) LIKE LOWER(CONCAT('%', :query, '%'))
            OR LOWER(m.description) LIKE LOWER(CONCAT('%', :query, '%'))
            OR LOWER(m.address) LIKE LOWER(CONCAT('%', :query, '%'))
          )
        ORDER BY m.time ASC, m.id ASC
        """,
    )
    fun searchDiscoveryMeetings(
        @Param("query") query: String,
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
    ): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        LEFT JOIN m.participants p
        WHERE m.status = :status
          AND COALESCE(m.endsAt, m.time) >= :now
          AND function('timepad_policy_visible', m.id, :now) = true
        GROUP BY m.id
        ORDER BY COUNT(p.id) DESC, m.time ASC, m.id ASC
        """,
    )
    fun findPopularDiscoveryMeetings(
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        LEFT JOIN m.participants p
        WHERE m.status = :status
          AND COALESCE(m.endsAt, m.time) >= :now
          AND function('timepad_policy_visible', m.id, :now) = true
          AND m.id NOT IN :excludedIds
        GROUP BY m.id
        ORDER BY COUNT(p.id) DESC, m.time ASC, m.id ASC
        """,
    )
    fun findPopularDiscoveryMeetingsExcluding(
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        @Param("excludedIds") excludedIds: Collection<Long>,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        JOIN m.participants p
        WHERE p.id = :userId
          AND function('timepad_policy_visible', m.id, :now) = true
        ORDER BY m.time DESC
        """,
    )
    fun findByParticipantId(@Param("userId") userId: Long, @Param("now") now: Long): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        WHERE m.id = :meetingId
          AND function('timepad_policy_visible', m.id, :now) = true
        """,
    )
    fun findVisibleById(@Param("meetingId") meetingId: Long, @Param("now") now: Long): Meeting?

    @Query(
        """
        SELECT m FROM Meeting m
        WHERE m.communityHost.id = :communityId
          AND m.status = :status
          AND function('timepad_policy_visible', m.id, :now) = true
        ORDER BY m.time ASC, m.id ASC
        """,
    )
    fun findVisibleByCommunity(
        @Param("communityId") communityId: Long,
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
    ): List<Meeting>

    @Query(
        """
        SELECT CASE WHEN COUNT(m) > 0 THEN true ELSE false END
        FROM Meeting m
        WHERE m.id = :meetingId
          AND function('timepad_policy_visible', m.id, :now) = true
        """,
    )
    fun isVisible(@Param("meetingId") meetingId: Long, @Param("now") now: Long): Boolean

    @Query(
        """
        SELECT CASE WHEN COUNT(m) > 0 THEN true ELSE false END
        FROM Meeting m
        JOIN m.participants p
        WHERE m.id = :meetingId AND p.id = :userId
          AND function('timepad_policy_visible', m.id, :now) = true
        """,
    )
    fun isVisibleParticipant(
        @Param("meetingId") meetingId: Long,
        @Param("userId") userId: Long,
        @Param("now") now: Long,
    ): Boolean

    @Query(
        """
        SELECT CASE WHEN COUNT(p) > 0 THEN true ELSE false END
        FROM Meeting m
        JOIN m.participants p
        WHERE m.id = :meetingId AND p.id = :userId
        """,
    )
    fun isUserParticipant(
        @Param("meetingId") meetingId: Long,
        @Param("userId") userId: Long,
    ): Boolean

    /** Поиск существующего внешнего события для идемпотентного upsert. */
    fun findBySourceAndSourceExternalId(
        source: EventSource,
        sourceExternalId: String,
    ): Meeting?

    fun deleteBySource(source: EventSource): Int

}
