package dev.whysoezzy.meet.ingestion.timepad

import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.time.Instant
import tools.jackson.databind.ObjectMapper
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TimepadPolicyTest {
    @ParameterizedTest
    @ValueSource(strings = [
        "школьника", "школьный", "школьная", "дошкольный", "детского", "подростковый",
        "детям", "детей", "дети", "ребёнка", "ребенку", "ребятам", "kids", "children",
        "учеников средней школы", "учащихся школы",
        "high school students", "primary school pupils", "school students", "for minors", "teens",
        "high schoolers", "for your child", "kid", "teen", "teenager", "schoolboy", "schoolgirl",
        "toddlers", "preschoolers", "несовершеннолетних", "малолетнего",
    ])
    fun `inflected child audience rejects title or category signals`(audience: String) {
        assertNull(TimepadPolicy.groups("Kotlin $audience", emptyList()))
        assertNull(TimepadPolicy.groups("Kotlin", listOf(audience)))
    }

    @Test
    fun `adult professional schools and school software topics are not audience markers`() {
        assertEquals(listOf(TimepadGroup.IT), TimepadPolicy.groups("Kotlin backend school", emptyList()))
        assertEquals(listOf(TimepadGroup.IT), TimepadPolicy.groups("Kotlin software for schools", emptyList()))
        assertEquals(listOf(TimepadGroup.IT), TimepadPolicy.groups("Kotlin child process management", emptyList()))
        assertEquals(listOf(TimepadGroup.IT), TimepadPolicy.groups("Python child processes", emptyList()))
        assertEquals(listOf(TimepadGroup.IT), TimepadPolicy.groups("Kotlin child coroutines", emptyList()))
    }

    @ParameterizedTest
    @ValueSource(
        strings = [
            "Android", "Kotlin", "Java", "Python", "backend", "frontend", "DevOps", "Kubernetes",
            "software development", "разработка ПО", "машинное обучение", "data science",
            "кибербезопасность",
        ],
    )
    fun `IT terms classify independently`(term: String) {
        assertEquals(listOf(TimepadGroup.IT), TimepadPolicy.groups(term, emptyList()))
    }

    @ParameterizedTest
    @ValueSource(
        strings = [
            "product management", "product manager", "product owner", "управление продуктом",
            "цифровой продукт", "продакт-менеджмент",
        ],
    )
    fun `product terms classify independently`(term: String) {
        assertEquals(listOf(TimepadGroup.PRODUCT), TimepadPolicy.groups(term, emptyList()))
    }

    @ParameterizedTest
    @ValueSource(
        strings = [
            "UX", "UI", "UX/UI", "UI/UX", "Figma", "дизайн интерфейсов", "цифровой дизайн",
        ],
    )
    fun `design terms classify independently`(term: String) {
        assertEquals(listOf(TimepadGroup.DESIGN), TimepadPolicy.groups(term, emptyList()))
    }

    @ParameterizedTest
    @ValueSource(
        strings = [
            "дизайн интерьера", "дизайн интерьеров", "interior design", "дизайн одежды",
            "fashion design", "мода", "для детей", "детский", "детская", "детское", "детские",
            "для школьников", "школьникам", "школьников", "для подростков", "подросткам",
            "детско-родительский", "детско-родительская", "семейный праздник",
            "семейный фестиваль", "for children", "for kids", "kids coding", "children coding",
            "schoolchildren", "for teenagers", "test event", "demo event",
            "тестовое событие", "демонстрационное событие",
        ],
    )
    fun `override terms reject positive titles`(override: String) {
        assertNull(TimepadPolicy.groups("Kotlin $override", emptyList()))
    }

    @Test
    fun `word boundaries do not reject software testing product demo or generic categories`() {
        assertEquals(listOf(TimepadGroup.IT), TimepadPolicy.groups("Software testing with Kotlin", emptyList()))
        assertEquals(listOf(TimepadGroup.PRODUCT), TimepadPolicy.groups("Product manager demo: roadmap", emptyList()))
        assertNull(TimepadPolicy.groups("ИТ и интернет", listOf("ИТ и интернет")))
        assertNull(TimepadPolicy.groups("Дизайн", listOf("дизайн")))
        assertNull(TimepadPolicy.groups("product", listOf("product")))
        assertNull(TimepadPolicy.groups("Аналитика", listOf("аналитика")))
    }

    @Test
    fun `group ordering and exclusions are deterministic across title and categories`() {
        assertEquals(
            listOf(TimepadGroup.IT, TimepadGroup.PRODUCT, TimepadGroup.DESIGN),
            TimepadPolicy.groups(
                "Figma product owner Kotlin",
                listOf("UX/UI", "цифровой продукт", "backend"),
            ),
        )
        assertNull(TimepadPolicy.groups("Roadmap", listOf("product manager для подростков")))
    }

    @ParameterizedTest
    @ValueSource(strings = ["Moscow", "МО", "Москва", "г. Москва", "Онлайн"])
    fun `non-Moscow city variants fail closed`(city: String) {
        if (city.equals("Москва", true) || city.equals("г. Москва", true)) {
            assertEquals(
                "ул. Пример, 1",
                TimepadPolicy.physicalMoscowAddress(city, "ул. Пример, 1"),
            )
        } else {
            assertNull(TimepadPolicy.physicalMoscowAddress(city, "ул. Пример, 1"))
        }
    }

    @ParameterizedTest
    @ValueSource(
        strings = [
            "", "Москва", "Moscow", "г Москва", "адрес уточняется", "место уточняется",
            "будет объявлено", "TBA", "TBD", "...", "ул. Пример онлайн",
            "ул. Пример дистанционно",
        ],
    )
    fun `nonphysical and conflicted addresses fail closed`(address: String) {
        assertNull(TimepadPolicy.physicalMoscowAddress("Москва", address))
    }

    @Test
    fun `registration URL is strict and tied to the event id`() {
        assertEquals(
            "https://timepad.ru/event/42/",
            TimepadPolicy.validRegistrationUrl("https://timepad.ru/event/42/", 42),
        )
        listOf(
            "http://timepad.ru/event/42/",
            "https://timepad.ru/event/41/",
            "https://timepad.ru/event/42",
            "https://timepad.ru.evil.test/event/42/",
            "https://timepad.ru/event/42/?x=1",
            "https://timepad.ru/event/42/#fragment",
            "https://user@timepad.ru/event/42/",
            "https://timepad.ru:444/event/42/",
            "https://timepad.ru/event/%34%32/",
        ).forEach { assertNull(TimepadPolicy.validRegistrationUrl(it, 42), it) }
    }

    @Test
    fun `locale public status registration and dates require explicit facts`() {
        assertTrue(TimepadPolicy.isRussianLocale("ru"))
        assertTrue(TimepadPolicy.isRussianLocale("RU-ru"))
        assertFalse(TimepadPolicy.isRussianLocale(null))
        assertFalse(TimepadPolicy.isRussianLocale("en"))
        assertTrue(TimepadPolicy.isPublic("PUBLIC"))
        assertFalse(TimepadPolicy.isPublic(null))
        assertFalse(TimepadPolicy.registrationOpen(null))
        val registration = ObjectMapper().readTree("""{"is_registration_open":true}""")
        assertTrue(TimepadPolicy.registrationOpen(registration))
        assertFalse(TimepadPolicy.registrationOpen(ObjectMapper().readTree("""{"is_registration_open":"true"}""")))

        val now = Instant.parse("2026-10-21T10:00:00Z").toEpochMilli()
        assertTrue(TimepadPolicy.eventStartAllowed(now + 1, now, false, null))
        assertTrue(TimepadPolicy.eventStartAllowed(now + 180L * 86_400_000, now, false, null))
        assertFalse(TimepadPolicy.eventStartAllowed(now, now, false, null))
        assertFalse(TimepadPolicy.eventStartAllowed(now + 180L * 86_400_000 + 1, now, false, null))
        assertTrue(TimepadPolicy.eventStartAllowed(now - 1, now, true, now + 1))
        assertFalse(TimepadPolicy.eventStartAllowed(now - 1, now, true, now))
    }

    @Test
    fun `description is factual and ordered`() {
        val starts = Instant.parse("2026-12-15T16:00:00Z").toEpochMilli()
        assertEquals(
            "Тема: IT, Цифровой продукт, UX/UI-дизайн. Формат: Очно. Начало: 15.12.2026 19:00 МСК. " +
                "Место: ул. Пример, 1. Источник: Timepad. Регистрация и актуальные условия — на странице события. " +
                "Интерес в приложении не является регистрацией.",
            TimepadPolicy.description(TimepadGroup.entries, starts, "ул. Пример, 1"),
        )
    }
}
