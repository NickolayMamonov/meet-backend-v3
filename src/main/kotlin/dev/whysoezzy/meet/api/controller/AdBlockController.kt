package dev.whysoezzy.meet.api.controller


import dev.whysoezzy.meet.api.dto.AdBlockResponseDto
import dev.whysoezzy.meet.api.dto.toDto
import dev.whysoezzy.meet.api.dto.toDtoList
import dev.whysoezzy.meet.service.AdBlockService
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/ads")
class AdBlockController(
    private val adBlockService: AdBlockService
) {

    @GetMapping
    fun getAllActiveAdBlocks(): ResponseEntity<List<AdBlockResponseDto>> {
        val adBlocks = adBlockService.getAllActiveAdBlocks()
        return ResponseEntity.ok(adBlocks.toDtoList())
    }

    @GetMapping("/{id}")
    fun getAdBlockById(@PathVariable id: Long): ResponseEntity<AdBlockResponseDto> {
        val adBlock = adBlockService.getAdBlockById(id)
        return adBlock?.let { ResponseEntity.ok(it.toDto()) } ?: ResponseEntity.ok().build()
    }
}
