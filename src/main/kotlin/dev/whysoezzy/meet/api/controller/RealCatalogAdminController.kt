package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.RealCatalogApplyRequest
import dev.whysoezzy.meet.api.dto.RealCatalogPreviewRequest
import dev.whysoezzy.meet.catalog.RealCatalogService
import jakarta.validation.Valid
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/admin/real-catalog")
@ConditionalOnProperty(prefix = "app.real-catalog", name = ["enabled"], havingValue = "true")
class RealCatalogAdminController(
    private val service: RealCatalogService,
) {
    @PostMapping("/preview")
    fun preview(@Valid @RequestBody request: RealCatalogPreviewRequest) =
        ResponseEntity.ok(service.preview(request))

    @PostMapping("/apply")
    fun apply(@Valid @RequestBody request: RealCatalogApplyRequest) =
        ResponseEntity.ok(service.apply(request))
}
