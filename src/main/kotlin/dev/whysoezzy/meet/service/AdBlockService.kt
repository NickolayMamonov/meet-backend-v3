package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.domain.entity.AdBlock
import dev.whysoezzy.meet.domain.repository.AdBlockRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

@Service
@Transactional(readOnly = true)
class AdBlockService(
    private val adBlockRepository: AdBlockRepository
) {

    fun getAllActiveAdBlocks(): List<AdBlock> {
        return adBlockRepository.findByIsActiveTrue()
    }

    fun getAdBlockById(id: Long): AdBlock? {
        return adBlockRepository.findById(id).orElse(null)
    }
}