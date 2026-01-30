package dev.whysoezzy.meet

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication
class MeetBackendApplication

fun main(args: Array<String>) {
    runApplication<MeetBackendApplication>(*args)
}
