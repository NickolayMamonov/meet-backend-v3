package dev.whysoezzy.meet.api.controller

import org.springframework.core.io.ClassPathResource
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController

@RestController
class DemoCatalogPublicAssetsController {
    @GetMapping("/demo-events/organize-online", produces = [MediaType.TEXT_HTML_VALUE])
    fun organizeOnline(): ResponseEntity<ByteArray> = html("static/demo-events/organize-online")

    @GetMapping("/demo-events/networking-online", produces = [MediaType.TEXT_HTML_VALUE])
    fun networkingOnline(): ResponseEntity<ByteArray> = html("static/demo-events/networking-online")

    private fun html(path: String): ResponseEntity<ByteArray> =
        ResponseEntity.ok()
            .contentType(MediaType("text", "html", Charsets.UTF_8))
            .body(ClassPathResource(path).inputStream.use { it.readBytes() })
}
