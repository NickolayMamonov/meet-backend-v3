package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.Community
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import org.springframework.stereotype.Repository

@Repository
interface CommunityRepository : JpaRepository<Community, Long> {
    
    @Query("""
        SELECT c FROM Community c
        WHERE LOWER(c.name) LIKE LOWER(CONCAT('%', :query, '%'))
        OR LOWER(c.description) LIKE LOWER(CONCAT('%', :query, '%'))
    """)
    fun searchCommunities(@Param("query") query: String): List<Community>
    
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
