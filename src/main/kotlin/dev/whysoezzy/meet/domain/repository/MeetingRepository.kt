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
    fun findAllByRealCatalogKey(catalogKey: String): List<Meeting>
    fun findByRealCatalogKeyAndRealCatalogItemKey(catalogKey: String, itemKey: String): Meeting?

    @Query(
        "SELECT m.realCatalogKey FROM Meeting m WHERE m.id = :meetingId",
    )
    fun findRealCatalogKeyById(@Param("meetingId") meetingId: Long): String?

    @Query(
        value = "SELECT real_catalog_key FROM meetings WHERE id = :meetingId FOR UPDATE",
        nativeQuery = true,
    )
    fun lockRealCatalogKeyById(@Param("meetingId") meetingId: Long): String?

    @Query(
        """
        SELECT m.* FROM meetings m
        LEFT JOIN real_catalog_state state ON state.catalog_key = m.real_catalog_key
        WHERE m.status = :#{#status.name()}
          AND COALESCE(m.ends_at, m.time) >= :now
          AND (
            m.real_catalog_key IS NULL
            OR (
                m.real_catalog_active = TRUE
                AND state.invitation_at <= to_timestamp(:now / 1000.0)
                AND state.discoverable_until > to_timestamp(:now / 1000.0)
            )
          )
        ORDER BY m.time ASC, m.id ASC
        """,
        nativeQuery = true,
    )
    fun findDiscoveryMeetings(
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m.* FROM meetings m
        LEFT JOIN real_catalog_state state ON state.catalog_key = m.real_catalog_key
        WHERE m.status = :#{#status.name()}
          AND COALESCE(m.ends_at, m.time) >= :now
          AND m.id NOT IN (:excludedIds)
          AND (
            m.real_catalog_key IS NULL
            OR (
                m.real_catalog_active = TRUE
                AND state.invitation_at <= to_timestamp(:now / 1000.0)
                AND state.discoverable_until > to_timestamp(:now / 1000.0)
            )
          )
        ORDER BY m.time ASC, m.id ASC
        """,
        nativeQuery = true,
    )
    fun findDiscoveryMeetingsExcluding(
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        @Param("excludedIds") excludedIds: Collection<Long>,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m.* FROM meetings m
        JOIN meeting_tags mt ON mt.meeting_id = m.id
        LEFT JOIN real_catalog_state state ON state.catalog_key = m.real_catalog_key
        WHERE m.status = :#{#status.name()}
          AND mt.tag_id = :tagId
          AND COALESCE(m.ends_at, m.time) >= :now
          AND (
            m.real_catalog_key IS NULL
            OR (
                m.real_catalog_active = TRUE
                AND state.invitation_at <= to_timestamp(:now / 1000.0)
                AND state.discoverable_until > to_timestamp(:now / 1000.0)
            )
          )
        ORDER BY m.time ASC, m.id ASC
        """,
        nativeQuery = true,
    )
    fun findDiscoveryMeetingsByTag(
        @Param("tagId") tagId: Long,
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m.* FROM meetings m
        LEFT JOIN real_catalog_state state ON state.catalog_key = m.real_catalog_key
        WHERE m.status = :#{#status.name()}
          AND COALESCE(m.ends_at, m.time) >= :now
          AND (
            LOWER(m.title) LIKE LOWER(CONCAT('%', :query, '%'))
            OR LOWER(m.description) LIKE LOWER(CONCAT('%', :query, '%'))
            OR LOWER(m.address) LIKE LOWER(CONCAT('%', :query, '%'))
          )
          AND (
            m.real_catalog_key IS NULL
            OR (
                m.real_catalog_active = TRUE
                AND state.invitation_at <= to_timestamp(:now / 1000.0)
                AND state.discoverable_until > to_timestamp(:now / 1000.0)
            )
          )
        ORDER BY m.time ASC, m.id ASC
        """,
        nativeQuery = true,
    )
    fun searchDiscoveryMeetings(
        @Param("query") query: String,
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
    ): List<Meeting>

    @Query(
        """
        SELECT m.* FROM meetings m
        LEFT JOIN meeting_participants p ON p.meeting_id = m.id
        LEFT JOIN real_catalog_state state ON state.catalog_key = m.real_catalog_key
        WHERE m.status = :#{#status.name()}
          AND COALESCE(m.ends_at, m.time) >= :now
          AND (
            m.real_catalog_key IS NULL
            OR (
                m.real_catalog_active = TRUE
                AND state.invitation_at <= to_timestamp(:now / 1000.0)
                AND state.discoverable_until > to_timestamp(:now / 1000.0)
            )
          )
        GROUP BY m.id
        ORDER BY COUNT(p.user_id) DESC, m.time ASC, m.id ASC
        """,
        nativeQuery = true,
    )
    fun findPopularDiscoveryMeetings(
        @Param("status") status: MeetingStatus,
        @Param("now") now: Long,
        pageable: Pageable,
    ): List<Meeting>

    @Query(
        """
        SELECT m.* FROM meetings m
        LEFT JOIN meeting_participants p ON p.meeting_id = m.id
        LEFT JOIN real_catalog_state state ON state.catalog_key = m.real_catalog_key
        WHERE m.status = :#{#status.name()}
          AND COALESCE(m.ends_at, m.time) >= :now
          AND m.id NOT IN (:excludedIds)
          AND (
            m.real_catalog_key IS NULL
            OR (
                m.real_catalog_active = TRUE
                AND state.invitation_at <= to_timestamp(:now / 1000.0)
                AND state.discoverable_until > to_timestamp(:now / 1000.0)
            )
          )
        GROUP BY m.id
        ORDER BY COUNT(p.user_id) DESC, m.time ASC, m.id ASC
        """,
        nativeQuery = true,
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

    @Query(
        value = """
            SELECT m.* FROM meetings m
            WHERE m.community_host_id = :communityId
              AND m.status = 'ACTIVE'
              AND (
                m.real_catalog_key IS NULL
                OR (
                    m.real_catalog_active = TRUE
                    AND EXISTS (
                        SELECT 1 FROM real_catalog_state state
                        WHERE state.catalog_key = m.real_catalog_key
                          AND state.invitation_at <= to_timestamp(:now / 1000.0)
                          AND state.discoverable_until > to_timestamp(:now / 1000.0)
                    )
                )
              )
            ORDER BY m.time ASC, m.id ASC
            LIMIT 5
        """,
        nativeQuery = true,
    )
    fun findDiscoverySiblings(
        @Param("communityId") communityId: Long,
        @Param("now") now: Long,
    ): List<Meeting>

    @Query(
        value = """
            SELECT m.* FROM meetings m
            WHERE m.community_host_id = :communityId
              AND m.status = 'ACTIVE'
              AND (
                m.real_catalog_key IS NULL
                OR (
                    m.real_catalog_active = TRUE
                    AND EXISTS (
                        SELECT 1 FROM real_catalog_state state
                        WHERE state.catalog_key = m.real_catalog_key
                          AND state.invitation_at <= to_timestamp(:now / 1000.0)
                          AND state.discoverable_until > to_timestamp(:now / 1000.0)
                    )
                )
              )
            ORDER BY m.time ASC, m.id ASC
        """,
        nativeQuery = true,
    )
    fun findDiscoveryCommunityMeetings(
        @Param("communityId") communityId: Long,
        @Param("now") now: Long,
    ): List<Meeting>

    @Query(
        value = """
            SELECT CASE WHEN COUNT(*) > 0 THEN TRUE ELSE FALSE END
            FROM meetings m
            LEFT JOIN real_catalog_state state ON state.catalog_key = m.real_catalog_key
            WHERE m.id = :meetingId
              AND (
                m.real_catalog_key IS NULL
                OR (
                    m.real_catalog_active = TRUE
                    AND state.invitation_at <= to_timestamp(:now / 1000.0)
                    AND state.discoverable_until > to_timestamp(:now / 1000.0)
                )
              )
        """,
        nativeQuery = true,
    )
    fun isFreshForParticipation(
        @Param("meetingId") meetingId: Long,
        @Param("now") now: Long,
    ): Boolean

    /** Поиск существующего внешнего события для идемпотентного upsert. */
    fun findBySourceAndSourceExternalId(
        source: EventSource,
        sourceExternalId: String,
    ): Meeting?

    fun deleteBySource(source: EventSource): Int

}
