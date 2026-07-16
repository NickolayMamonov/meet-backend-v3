package dev.whysoezzy.meet

import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.JwtConfigurationInitializer
import dev.whysoezzy.meet.config.JwtProperties
import org.springframework.boot.SpringApplication
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.EnableConfigurationProperties

@SpringBootApplication
@EnableConfigurationProperties(GeocoderProperties::class, JwtProperties::class)
class MeetBackendApplication

fun main(args: Array<String>) {
    SpringApplication(MeetBackendApplication::class.java)
        .apply { addInitializers(JwtConfigurationInitializer()) }
        .run(*args)
}
