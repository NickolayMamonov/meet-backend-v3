package dev.whysoezzy.meet.domain.repository

import dev.whysoezzy.meet.domain.entity.Tag
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface TagRepository : JpaRepository<Tag, Long> {
    fun findAllByDemoCatalogKeyIn(keys: Collection<String>): List<Tag>

    fun findByText(text: String): Tag?
}
