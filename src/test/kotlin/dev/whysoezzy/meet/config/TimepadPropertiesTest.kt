package dev.whysoezzy.meet.config

import org.junit.jupiter.api.Test
import kotlin.test.assertFailsWith

class TimepadPropertiesTest {
    @Test
    fun `enabled feed requires fixed trusted API and HTTPS assets`() {
        TimepadProperties().apply {
            enabled = true
            assetBaseUrl = "https://assets.example"
            validate()
        }
        assertFailsWith<IllegalArgumentException> {
            TimepadProperties().apply {
                enabled = true
                baseUrl = "https://api.timepad.ru.attacker.example/v1"
                assetBaseUrl = "https://assets.example"
                validate()
            }
        }
        assertFailsWith<IllegalArgumentException> {
            TimepadProperties().apply {
                enabled = true
                assetBaseUrl = "http://assets.example"
                validate()
            }
        }
    }

    @Test
    fun `enabled feed refuses altered bounds and timezone`() {
        assertFailsWith<IllegalArgumentException> {
            TimepadProperties().apply {
                enabled = true
                assetBaseUrl = "https://assets.example"
                pageSize = 99
                validate()
            }
        }
        assertFailsWith<IllegalArgumentException> {
            TimepadProperties().apply {
                enabled = true
                assetBaseUrl = "https://assets.example"
                maxPages = 6
                validate()
            }
        }
    }
}
