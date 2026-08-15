package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import org.springframework.data.domain.Pageable
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import org.springframework.stereotype.Repository

@Repository
interface MeetingRepository : JpaRepository<Meeting, Long> {
    fun findAllByDemoCatalogKeyIn(keys: Collection<String>): List<Meeting>

    @Query(
        """
        SELECT m FROM Meeting m
        WHERE m.status = :status
          AND COALESCE(m.endsAt, m.time) >= :now
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
        ORDER BY m.time DESC
        """,
    )
    fun findByParticipantId(@Param("userId") userId: Long): List<Meeting>

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
