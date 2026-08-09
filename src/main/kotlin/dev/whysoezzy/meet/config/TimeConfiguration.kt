package dev.whysoezzy.meet.config

import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import java.time.Clock

@Configuration
class TimeConfiguration {
    @Bean
    fun utcClock(): Clock = Clock.systemUTC()
}
