package dev.whysoezzy.meet

import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.JwtProperties
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.EnableConfigurationProperties
import org.springframework.boot.runApplication

@SpringBootApplication
@EnableConfigurationProperties(GeocoderProperties::class, JwtProperties::class)
class MeetBackendApplication

fun main(args: Array<String>) {
    runApplication<MeetBackendApplication>(*args)
}
