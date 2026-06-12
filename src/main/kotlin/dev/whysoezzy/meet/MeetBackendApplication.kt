package dev.whysoezzy.meet

import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.StaticMapProperties
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.EnableConfigurationProperties
import org.springframework.boot.runApplication

@SpringBootApplication
@EnableConfigurationProperties(GeocoderProperties::class, StaticMapProperties::class)
class MeetBackendApplication

fun main(args: Array<String>) {
    runApplication<MeetBackendApplication>(*args)
}
