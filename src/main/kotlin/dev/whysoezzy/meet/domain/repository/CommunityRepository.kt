package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.Community
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import org.springframework.stereotype.Repository

@Repository
interface CommunityRepository : JpaRepository<Community, Long> {
    fun findAllByDemoCatalogKeyIn(keys: Collection<String>): List<Community>
    fun findAllByRealCatalogKey(catalogKey: String): List<Community>
    fun findByRealCatalogKeyAndRealCatalogItemKey(catalogKey: String, itemKey: String): Community?

    @Query(
        value = """
            SELECT c.* FROM communities c
            LEFT JOIN real_catalog_state state ON state.catalog_key = c.real_catalog_key
            WHERE (
                c.real_catalog_key IS NULL
                OR (c.real_catalog_active = TRUE AND state.discoverable_until > to_timestamp(:now / 1000.0))
            )
            ORDER BY c.id ASC
        """,
        nativeQuery = true,
    )
    fun findDiscoveryCommunities(@Param("now") now: Long, pageable: org.springframework.data.domain.Pageable): List<Community>

    
    @Query("""
        SELECT c FROM Community c
        WHERE LOWER(c.name) LIKE LOWER(CONCAT('%', :query, '%'))
        OR LOWER(c.description) LIKE LOWER(CONCAT('%', :query, '%'))
    """)
    fun searchCommunities(@Param("query") query: String): List<Community>

    @Query(
        value = """
            SELECT c.* FROM communities c
            LEFT JOIN real_catalog_state state ON state.catalog_key = c.real_catalog_key
            WHERE (
                LOWER(c.name) LIKE LOWER(CONCAT('%', :query, '%'))
                OR LOWER(c.description) LIKE LOWER(CONCAT('%', :query, '%'))
            )
            AND (
                c.real_catalog_key IS NULL
                OR (c.real_catalog_active = TRUE AND state.discoverable_until > to_timestamp(:now / 1000.0))
            )
            ORDER BY c.id ASC
        """,
        nativeQuery = true,
    )
    fun searchDiscoveryCommunities(@Param("query") query: String, @Param("now") now: Long): List<Community>

    @Query(
        value = """
            SELECT CASE WHEN COUNT(*) > 0 THEN TRUE ELSE FALSE END
            FROM communities c
            LEFT JOIN real_catalog_state state ON state.catalog_key = c.real_catalog_key
            WHERE c.id = :communityId
              AND (
                c.real_catalog_key IS NULL
                OR (
                    c.real_catalog_active = TRUE
                    AND state.discoverable_until > to_timestamp(:now / 1000.0)
                )
              )
        """,
        nativeQuery = true,
    )
    fun isFreshForParticipation(@Param("communityId") communityId: Long, @Param("now") now: Long): Boolean
    
    @Query("""
        SELECT CASE WHEN COUNT(u) > 0 THEN true ELSE false END
        FROM Community c
        JOIN c.subscribers u
        WHERE c.id = :communityId AND u.id = :userId
    """)
    fun isUserSubscribed(
        @Param("communityId") communityId: Long,
        @Param("userId") userId: Long
    ): Boolean
}
