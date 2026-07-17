package dev.whysoezzy.meet

import dev.whysoezzy.meet.config.AdminProperties
import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.JwtConfigurationInitializer
import dev.whysoezzy.meet.config.JwtProperties
import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import dev.whysoezzy.meet.config.SmsProperties
import org.springframework.boot.SpringApplication
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.EnableConfigurationProperties

@SpringBootApplication
@EnableConfigurationProperties(
    AdminProperties::class,
    GeocoderProperties::class,
    JwtProperties::class,
    OtpProperties::class,
    OtpRateLimitProperties::class,
    SmsProperties::class,
)
class MeetBackendApplication

fun main(args: Array<String>) {
    SpringApplication(MeetBackendApplication::class.java)
        .apply { addInitializers(JwtConfigurationInitializer()) }
        .run(*args)
}
