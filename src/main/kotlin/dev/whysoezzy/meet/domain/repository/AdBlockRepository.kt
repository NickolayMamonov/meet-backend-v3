package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.AdBlock
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface AdBlockRepository : JpaRepository<AdBlock, Long> {
    fun findAllByDemoCatalogKeyIn(keys: Collection<String>): List<AdBlock>

    fun findByIsActiveTrue(): List<AdBlock>
}
