package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.dto.AdBlockResponseDto
import dev.whysoezzy.meet.api.dto.toDto
import dev.whysoezzy.meet.domain.repository.AdBlockRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

@Service
@Transactional(readOnly = true)
class AdBlockService(
    private val adBlockRepository: AdBlockRepository
) {

    fun getAllActiveAdBlocks(): List<AdBlockResponseDto> {
        return adBlockRepository.findByIsActiveTrue().map { it.toDto() }
    }

    fun getAdBlockById(id: Long): AdBlockResponseDto? {
        return adBlockRepository.findById(id).orElse(null)?.toDto()
    }
}
