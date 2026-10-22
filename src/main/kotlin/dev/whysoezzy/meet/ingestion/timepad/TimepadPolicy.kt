package dev.whysoezzy.meet.ingestion.timepad

import tools.jackson.databind.JsonNode
import java.net.URI
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

enum class TimepadGroup(val displayName: String, val asset: String) {
    IT("IT", "it"),
    PRODUCT("Цифровой продукт", "product"),
    DESIGN("UX/UI-дизайн", "design"),
}

object TimepadPolicy {
    const val VERSION = "timepad-mvp-v1"
    val MOSCOW: ZoneId = ZoneId.of("Europe/Moscow")

    private val included = linkedMapOf(
        TimepadGroup.IT to listOf(
            "android", "kotlin", "java", "python", "backend", "frontend", "devops",
            "kubernetes", "software development", "разработка ПО", "машинное обучение",
            "data science", "кибербезопасность",
        ),
        TimepadGroup.PRODUCT to listOf(
            "product management", "product manager", "product owner",
            "управление продуктом", "цифровой продукт", "продакт-менеджмент",
        ),
        TimepadGroup.DESIGN to listOf(
            "ux", "ui", "ux/ui", "ui/ux", "figma", "дизайн интерфейсов", "цифровой дизайн",
        ),
    )
    private val excluded = listOf(
        "дизайн интерьера", "дизайн интерьеров", "interior design", "дизайн одежды",
        "fashion design", "мода", "для детей", "детский", "детская", "детское", "детские",
        "для школьников", "школьникам", "школьников", "для подростков", "подросткам",
        "детско-родительский", "детско-родительская", "семейный праздник",
        "семейный фестиваль", "for children", "for kids", "kids coding", "children coding",
        "schoolchildren", "for teenagers", "test event", "demo event", "тестовое событие",
        "демонстрационное событие",
    )
    private val tokens = listOf(
        "дизайн интерьера", "дизайн интерьеров", "interior design", "дизайн одежды",
        "fashion design", "семейный праздник", "семейный фестиваль", "for children",
        "for kids", "kids coding", "children coding", "schoolchildren", "for teenagers",
        "test event", "demo event", "тестовое событие", "демонстрационное событие",
        "продакт-менеджмент", "product management", "product manager", "product owner",
        "software development", "разработка по", "машинное обучение", "data science",
        "кибербезопасность", "управление продуктом", "цифровой продукт",
        "дизайн интерфейсов", "цифровой дизайн", "ux/ui", "ui/ux",
    )
    private val childWords = listOf(
        "детский", "детская", "детское", "детские", "школьникам", "школьников",
        "подросткам", "детско-родительский", "детско-родительская",
    )
    // Russian audience adjectives/nouns inflect; enumerating phrases misses singular cases.
    private val childAudience = Regex(
        "(?<![\\p{L}\\p{N}\\p{M}_])(?:(?:дошкольн|школьн|детск|подростк|малолетн|несовершеннолетн)[\\p{L}\\p{M}]*|" +
            "дет(?:и|ей|ям|ьми|ях)|реб(?:[её]нок|[её]нка|[её]нку|[её]нком|[её]нке|ята|ят|ятам|ятами|ятах)|" +
            "children|kids?|teen(?:ager)?s?|school(?:children|kids?|boys?|girls?|ers?)|" +
            "toddlers?|preschoolers?)(?![\\p{L}\\p{N}\\p{M}_])",
    )
    private val schoolAudience = Regex(
        "(?<![\\p{L}\\p{N}\\p{M}_])(?:ученик|учениц|учащ)[\\p{L}\\p{M}]*\\s+" +
            "(?:[\\p{L}\\p{M}]+\\s+){0,4}школ(?:а|ы|е|у|ой|ою|ам|ами|ах)?" +
            "(?![\\p{L}\\p{N}\\p{M}_])",
    )
    private val englishSchoolAudience = Regex(
        "(?<![\\p{L}\\p{N}\\p{M}_])(?:(?:(?:high|middle|primary|secondary|elementary)\\s+)?" +
            "school[\\s-]+(?:students?|pupils?)|for\\s+(?:pupils|minors))" +
            "(?![\\p{L}\\p{N}\\p{M}_])",
    )
    private val englishChildAudience = Regex(
        "(?<![\\p{L}\\p{N}\\p{M}_])for\\s+(?:(?:your|a|the|our|my|any|each)\\s+)?child" +
            "(?![\\p{L}\\p{N}\\p{M}_])",
    )
    private val rejectedExact = setOf(
        "test", "demo", "тест", "тестовое событие", "демонстрационное событие",
    )
    private val addressPlaceholders = setOf(
        "адрес уточняется", "место уточняется", "будет объявлено", "tba", "tbd",
    )

    fun groups(title: String, categoryNames: Collection<String>): List<TimepadGroup>? {
        val titleText = normalize(title)
        val categoryText = categoryNames.map(::normalize)
        val allText = listOf(titleText) + categoryText
        if (allText.any {
            childAudience.containsMatchIn(it) || schoolAudience.containsMatchIn(it) ||
                englishSchoolAudience.containsMatchIn(it) || englishChildAudience.containsMatchIn(it)
        }) return null
        if (
            titleText in rejectedExact ||
            categoryText.any { it in rejectedExact } ||
            listOf("[test]", "[demo]", "[тест]", "[демо]").any(titleText::startsWith)
        ) return null

        val exclusions = excluded + childWords + listOf("мода")
        if (allText.any { text -> exclusions.any { text.containsWord(it) } }) return null

        return included.filterValues { phrases ->
            allText.any { text -> phrases.any { text.containsWord(it) } }
        }.keys.toList().takeIf { it.isNotEmpty() }
    }

    fun title(value: String): String? =
        value.trim().replace(Regex("\\s+"), " ").takeIf { it.isNotEmpty() && it.length <= 300 }

    fun isRussianLocale(value: String?): Boolean =
        value?.lowercase(Locale.ROOT) in setOf("ru", "ru-ru", "ru_ru")

    fun registrationOpen(node: JsonNode?): Boolean =
        node?.path("is_registration_open")?.takeIf(JsonNode::isBoolean)?.booleanValue() == true

    fun isPublic(value: String?): Boolean = value.equals("public", ignoreCase = true)

    fun physicalMoscowAddress(city: String?, address: String?): String? {
        val normalizedCity = normalize(city.orEmpty()).replace(".", "").trim(',', ' ')
        if (normalizedCity !in setOf("москва", "г москва", "город москва")) return null
        val physical = address?.trim()?.replace(Regex("\\s+"), " ")?.trim('.', ',', ' ')
            ?.takeIf(String::isNotBlank) ?: return null
        val normalized = normalize(physical)
        if (
            normalized in addressPlaceholders ||
            normalized in setOf("москва", "moscow", "г москва", "город москва") ||
            normalized.all { !it.isLetterOrDigit() }
        ) return null
        val online = listOf("онлайн", "online", "дистанционно", "remote")
            .any { normalized.containsWord(it) }
        if (online) return null
        return physical
    }

    fun validRegistrationUrl(value: String?, eventId: Long): String? {
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        val host = uri.host?.lowercase(Locale.ROOT) ?: return null
        if (
            uri.scheme != "https" ||
            !(host == "timepad.ru" || host.endsWith(".timepad.ru")) ||
            uri.rawPath != "/event/$eventId/" ||
            (uri.port != -1 && uri.port != 443) ||
            uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null
        ) return null
        return uri.toASCIIString()
    }

    fun description(groups: List<TimepadGroup>, startsAt: Long, address: String): String {
        val groupText = groups.joinToString(", ") { it.displayName }
        val local = java.time.Instant.ofEpochMilli(startsAt).atZone(MOSCOW)
        val date = local.format(DateTimeFormatter.ofPattern("dd.MM.yyyy HH:mm"))
        return "Тема: $groupText. Формат: Очно. Начало: $date МСК. Место: $address. " +
            "Источник: Timepad. Регистрация и актуальные условия — на странице события. " +
            "Интерес в приложении не является регистрацией."
    }

    fun parseTimestamp(value: String?, zone: ZoneId = MOSCOW): Long? {
        if (value.isNullOrBlank()) return null
        runCatching {
            return OffsetDateTime.parse(value, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssZ"))
                .toInstant().toEpochMilli()
        }
        runCatching { return OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant().toEpochMilli() }
        runCatching { return LocalDateTime.parse(value, DateTimeFormatter.ISO_LOCAL_DATE_TIME).atZone(zone).toInstant().toEpochMilli() }
        return runCatching { LocalDate.parse(value, DateTimeFormatter.ISO_LOCAL_DATE).atStartOfDay(zone).toInstant().toEpochMilli() }
            .getOrNull()
    }

    fun eventStartAllowed(start: Long, observedAt: Long, saved: Boolean, end: Long?): Boolean =
        if (saved) (end ?: start) > observedAt else start > observedAt && start <= observedAt + 180L * 24 * 60 * 60 * 1000

    fun categoryNames(node: JsonNode?): List<String> {
        if (node == null || (!node.isArray && !node.isObject)) return emptyList()
        return node.values().mapNotNull { element ->
            element.path("name").takeIf(JsonNode::isString)?.stringValue()
        }.filter(String::isNotBlank)
    }

    private fun normalize(value: String): String =
        value.lowercase(Locale.ROOT).replace(Regex("\\s+"), " ").trim()

    private fun String.containsWord(phrase: String): Boolean {
        val escaped = Regex.escape(normalize(phrase))
        return Regex("(?<![\\p{L}\\p{N}\\p{M}_])$escaped(?![\\p{L}\\p{N}\\p{M}_])")
            .containsMatchIn(this)
    }
}
