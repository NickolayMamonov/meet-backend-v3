package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.TagDto
import dev.whysoezzy.meet.domain.repository.TagRepository
import mu.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

private val logger = KotlinLogging.logger {}

@Service
class TagService(
    private val tagRepository: TagRepository
) {
    
    @Transactional(readOnly = true)
    fun getAllTags(): List<TagDto> {
        logger.info { "Fetching all tags" }
        
        return tagRepository.findAll()
            .map { TagDto(it.id!!, it.text) }
    }
}
