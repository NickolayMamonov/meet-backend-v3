package dev.whysoezzy.meet

import dev.whysoezzy.meet.config.AdminProperties
import dev.whysoezzy.meet.config.ClientIpProperties
import dev.whysoezzy.meet.config.DemoCatalogProperties
import dev.whysoezzy.meet.config.EmailProperties
import dev.whysoezzy.meet.config.GeocoderProperties
import dev.whysoezzy.meet.config.JwtProperties
import dev.whysoezzy.meet.config.OtpHashProperties
import dev.whysoezzy.meet.config.OtpProperties
import dev.whysoezzy.meet.config.OtpRateLimitProperties
import dev.whysoezzy.meet.config.OtpVerificationProperties
import dev.whysoezzy.meet.config.RuntimeConfigurationInitializer
import dev.whysoezzy.meet.config.SmsProperties
import org.springframework.boot.security.autoconfigure.UserDetailsServiceAutoConfiguration
import org.springframework.boot.SpringApplication
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.EnableConfigurationProperties

@SpringBootApplication(exclude = [UserDetailsServiceAutoConfiguration::class])
@EnableConfigurationProperties(
    AdminProperties::class,
    ClientIpProperties::class,
    DemoCatalogProperties::class,
    EmailProperties::class,
    GeocoderProperties::class,
    JwtProperties::class,
    OtpHashProperties::class,
    OtpProperties::class,
    OtpRateLimitProperties::class,
    OtpVerificationProperties::class,
    SmsProperties::class,
)
class MeetBackendApplication

fun main(args: Array<String>) {
    SpringApplication(MeetBackendApplication::class.java)
        .apply { addInitializers(RuntimeConfigurationInitializer()) }
        .run(*args)
}
