package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.Meeting
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import org.springframework.stereotype.Repository

@Repository
interface MeetingRepository : JpaRepository<Meeting, Long> {

    fun findAllByStatus(status: MeetingStatus): List<Meeting>

    @Query("""
        SELECT m FROM Meeting m
        JOIN m.tags t
        WHERE m.status = :status AND t.id = :tagId
        ORDER BY m.time ASC
    """)
    fun findByTagId(
        @Param("tagId") tagId: Long,
        @Param("status") status: MeetingStatus
    ): List<Meeting>

    @Query("""
        SELECT m FROM Meeting m
        WHERE m.status = :status
        AND m.time >= :currentTime
        ORDER BY m.time ASC
    """)
    fun findUpcomingMeetings(
        @Param("status") status: MeetingStatus,
        @Param("currentTime") currentTime: Long
    ): List<Meeting>

    @Query("""
        SELECT m FROM Meeting m
        LEFT JOIN m.participants p
        WHERE m.status = :status
        GROUP BY m.id
        ORDER BY COUNT(p) DESC, m.time ASC
    """)
    fun findPopularMeetings(
        @Param("status") status: MeetingStatus
    ): List<Meeting>

    @Query("""
        SELECT m FROM Meeting m
        WHERE m.status = :status
        AND (
            LOWER(m.title) LIKE LOWER(CONCAT('%', :query, '%'))
            OR LOWER(m.description) LIKE LOWER(CONCAT('%', :query, '%'))
            OR LOWER(m.address) LIKE LOWER(CONCAT('%', :query, '%'))
        )
        ORDER BY m.time ASC
    """)
    fun searchMeetings(
        @Param("query") query: String,
        @Param("status") status: MeetingStatus
    ): List<Meeting>

    @Query("""
        SELECT m FROM Meeting m
        JOIN m.participants p
        WHERE p.id = :userId
        ORDER BY m.time DESC
    """)
    fun findByParticipantId(@Param("userId") userId: Long): List<Meeting>

    @Query("""
        SELECT CASE WHEN COUNT(p) > 0 THEN true ELSE false END
        FROM Meeting m
        JOIN m.participants p
        WHERE m.id = :meetingId AND p.id = :userId
    """)
    fun isUserParticipant(
        @Param("meetingId") meetingId: Long,
        @Param("userId") userId: Long
    ): Boolean

    /** Поиск существующего внешнего события для идемпотентного upsert. */
    fun findBySourceAndSourceExternalId(
        source: EventSource,
        sourceExternalId: String
    ): Meeting?
}
