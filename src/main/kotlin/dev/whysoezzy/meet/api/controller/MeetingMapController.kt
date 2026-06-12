package dev.whysoezzy.meet.api.controller


import dev.whysoezzy.meet.domain.repository.MeetingRepository
import dev.whysoezzy.meet.service.StaticMapService
import org.springframework.http.CacheControl
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RestController
import java.time.Duration

@RestController
class MeetingMapController(
    private val meetings: MeetingRepository,
    private val staticMap: StaticMapService,
) {
    @GetMapping("/meetings/{id}/map.png", produces = [MediaType.IMAGE_PNG_VALUE])
    fun map(@PathVariable id: Long): ResponseEntity<ByteArray> {
        val m = meetings.findById(id).orElse(null) ?: return ResponseEntity.notFound().build()
        val lat = m.latitude
        val lon = m.longitude
        if (lat == 0.0 && lon == 0.0) return ResponseEntity.notFound().build()

        val png = staticMap.render(lat, lon)
            ?: return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build()
        return ResponseEntity.ok()
            .cacheControl(CacheControl.maxAge(Duration.ofDays(7)).cachePublic())
            .body(png)
    }
}