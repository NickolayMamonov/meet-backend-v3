package dev.whysoezzy.meet.ingestion

import org.springframework.stereotype.Component

@Component
class TopicClassifier {
    // Ключи = тексты тегов (то, что увидит клиент как chips). Значения = ключевые слова (lowercase).
    private val rules: Map<String, List<String>> = mapOf(
        "IT" to listOf(
            "ит и интернет",                       // категория Timepad → база для всех 452
            "разработ", "программир", "android", "ios", "kotlin", "java", "python",
            "javascript", "golang", "backend", "frontend", "fullstack", "devops",
            "kubernetes", "docker", "микросервис", "веб-разработ", "мобильн прилож",
            "developer", "архитектур", "api", "тестирован"
        ),
        "Data" to listOf(
            "больших данных", "анализ данных", "анализа данных", "обработк данных",
            "хранилищ данных", "база данных", "баз данных", "наук о данных",
            "аналитик", "big data", "data scien", "data engineer", "data analy",
            "машинн обуч", "машинного обуч", "machine learning", "нейросет",
            "искусственн интеллект", "spark", "hadoop", "kafka", "clickhouse", "etl", "dwh"
        ),
        "Дизайн" to listOf(
            "дизайн", "design", "ux", "ui/ux", "figma", "интерфейс", "юзабилит",
            "прототипир", "продакт", "продукт-менедж", "product manage", "product owner"
        ),
    )

    /** Возвращает тексты тегов тем, под которые подходит событие. Пусто — не релевантно. */
    fun classify(raw: RawEvent): Set<String> {
        val haystack = (raw.title + " " + raw.description + " " +
                raw.topicKeywords.joinToString(" ")).lowercase()
        return rules.filterValues { kws -> kws.any { haystack.contains(it) } }.keys
    }
}