package dev.whysoezzy.meet.ingestion

import org.springframework.stereotype.Component

@Component
class TopicClassifier {

    // Узкие теги: ключ — текст тега (chip у клиента), значение — ключевые слова (lowercase, подстрока).
    private val rules: Map<String, List<String>> = mapOf(
        "Android" to listOf(
            "android", "андроид", "jetpack", "jetpack compose",
            "kmp", "kmm", "kotlin multiplatform"
        ),
        "iOS" to listOf(
            "ios-разработ", "ios разработ", "swift", "swiftui", "айос"
        ),
        "Backend" to listOf(
            "backend", "бэкенд", "микросервис", "ktor", "spring", "nodejs", "node.js",
            "django", "сервер", "rest api", " api ", "база данных", "sql", "postgres", "highload"
        ),
        "Frontend" to listOf(
            "frontend", "фронтенд", "react", "vue", "angular",
            "javascript", "typescript", "верстк", " css", " html"
        ),
        "Mobile" to listOf(
            "мобильн прилож", "flutter", "react native"
        ),
        "DevOps" to listOf(
            "devops", "kubernetes", "docker", "ci/cd", "terraform", "ansible", "облачн инфра"
        ),
        "Data" to listOf(
            "больших данных", "анализ данных", "анализа данных", "обработк данных",
            "аналитик", "big data", "data scien", "data engineer", "data analy",
            "машинн обуч", "машинного обуч", "machine learning", "нейросет",
            "искусственн интеллект", "spark", "hadoop", "kafka", "clickhouse", "etl", "dwh"
        ),
        "QA" to listOf(
            "тестирован", " qa ", "qa-", "автотест", "автоматизац тест"
        ),
        "Security" to listOf(
            "безопасност", "пентест", "кибербез", "infosec", "security"
        ),
        "Дизайн" to listOf(
            "дизайн", "design", " ux", "ui/ux", "figma", "интерфейс",
            "юзабилит", "продакт", "product manage", "product owner"
        ),
    )

    /**
     * Возвращает узкие теги события. Если ни один не подошёл, но событие из ИТ-категории Timepad —
     * помечаем общим "IT" (чтобы не отфильтровать и не оставить без тега).
     */
    fun classify(raw: RawEvent): Set<String> {
        val hay = (raw.title + " " + raw.description + " " +
                raw.topicKeywords.joinToString(" ")).lowercase()

        val matched = rules.filterValues { kws -> kws.any { hay.contains(it) } }.keys
        return matched.ifEmpty {
            if (hay.contains("ит и интернет")) setOf("IT") else emptySet()
        }
    }
}