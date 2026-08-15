package dev.whysoezzy.meet.demo.catalog

import dev.whysoezzy.meet.domain.entity.AdBlockType
import dev.whysoezzy.meet.domain.entity.EventSource
import dev.whysoezzy.meet.domain.entity.MeetingStatus
import java.time.LocalTime

data class CatalogKey(val value: String) {
    init {
        require(value.isNotBlank() && value.length <= 160 && value.matches(Regex("[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+")))
    }
}

data class ManifestTag(val key: CatalogKey, val text: String)

data class ManifestUser(
    val key: CatalogKey,
    val name: String,
    val surname: String,
    val email: String,
    val city: String,
    val avatarUrl: String,
    val bio: String,
    val interests: Set<CatalogKey>,
)

data class ManifestCommunity(
    val key: CatalogKey,
    val name: String,
    val description: String,
    val imageUrl: String,
    val tags: Set<CatalogKey>,
    val subscribers: Set<CatalogKey>,
)

data class ManifestMeeting(
    val key: CatalogKey,
    val title: String,
    val description: String,
    val imageUrl: String,
    val dayOffset: Long,
    val localStart: LocalTime,
    val durationMinutes: Long,
    val address: String,
    val latitude: Double,
    val longitude: Double,
    val capacity: Int,
    val online: Boolean,
    val externalUrl: String?,
    val personHost: CatalogKey,
    val communityHost: CatalogKey,
    val tags: Set<CatalogKey>,
    val participants: Set<CatalogKey>,
    val status: MeetingStatus = MeetingStatus.ACTIVE,
    val source: EventSource = EventSource.MANUAL,
)

data class ManifestAdBlock(
    val key: CatalogKey,
    val type: AdBlockType,
    val title: String,
    val description: String,
    val actionText: String? = null,
    val actionUrl: String? = null,
    val communities: Set<CatalogKey> = emptySet(),
    val users: Set<CatalogKey> = emptySet(),
    val active: Boolean = true,
)

data class BetaDemoCatalogManifest(
    val catalogName: String,
    val manifestVersion: String,
    val tags: List<ManifestTag>,
    val users: List<ManifestUser>,
    val communities: List<ManifestCommunity>,
    val meetings: List<ManifestMeeting>,
    val adBlocks: List<ManifestAdBlock>,
) {
    val mediaUrls: Set<String>
        get() = buildSet {
            users.forEach { add(it.avatarUrl) }
            communities.forEach { add(it.imageUrl) }
            meetings.forEach { add(it.imageUrl) }
        }

    val publicLandingUrls: Set<String>
        get() = meetings.mapNotNull { it.externalUrl }.toSet()
}

object BetaDemoCatalog {
    const val CATALOG_NAME = "closed-beta-demo"
    const val MANIFEST_VERSION = "2026-08-15.v1"
    const val MEDIA_BASE = "https://api.whysoezzy.online/demo-assets/v1/"
    private fun key(type: String, slug: String) = CatalogKey("$CATALOG_NAME/$type/$slug")
    private fun tag(slug: String, text: String) = ManifestTag(key("tag", slug), text)
    private fun user(slug: String, number: Int, name: String, surname: String, city: String, bio: String, interests: Set<String>) =
        ManifestUser(
            key("user", slug),
            name,
            surname,
            "beta-demo-person-%02d@example.invalid".format(number),
            city,
            "${MEDIA_BASE}avatar-%02d.png".format(number),
            bio,
            interests.map { key("tag", it) }.toSet(),
        )
    private fun community(slug: String, name: String, description: String, image: String, tags: Set<String>, subscribers: Set<String>) =
        ManifestCommunity(
            key("community", slug),
            name,
            description,
            "$MEDIA_BASE$image",
            tags.map { key("tag", it) }.toSet(),
            subscribers.map { key("user", it) }.toSet(),
        )

    val manifest = BetaDemoCatalogManifest(
        CATALOG_NAME,
        MANIFEST_VERSION,
        listOf(
            tag("networking", "[ДЕМО] Нетворкинг"),
            tag("walks", "[ДЕМО] Прогулки"),
            tag("board-games", "[ДЕМО] Настольные игры"),
            tag("public-speaking", "[ДЕМО] Публичные выступления"),
            tag("organizing", "[ДЕМО] Организация встреч"),
            tag("online", "[ДЕМО] Онлайн"),
        ),
        listOf(
            user("01", 1, "[ДЕМО] Анна", "Волкова", "Москва", "Организует дружелюбные встречи для новых знакомств.", setOf("networking", "organizing")),
            user("02", 2, "[ДЕМО] Михаил", "Орлов", "Москва", "Любит городские прогулки и открывать новые места Москвы.", setOf("walks", "networking")),
            user("03", 3, "[ДЕМО] Елена", "Соколова", "Москва", "Помогает уверенно выступать и знакомиться с людьми.", setOf("public-speaking", "networking")),
            user("04", 4, "[ДЕМО] Павел", "Морозов", "Москва", "Собирает компании для современных настольных игр.", setOf("board-games", "networking")),
            user("05", 5, "[ДЕМО] Софья", "Лебедева", "Онлайн", "Проводит полезные и спокойные онлайн-встречи.", setOf("online", "organizing")),
            user("06", 6, "[ДЕМО] Илья", "Кузнецов", "Москва", "Участник демонстрационного каталога закрытой беты.", setOf("networking", "online")),
        ),
        listOf(
            community("moscow-meets", "[ДЕМО] Москва знакомится", "Демонстрационное сообщество закрытой беты для дружелюбных знакомств и небольших встреч в Москве.", "community-moscow.png", setOf("networking", "organizing"), setOf("01", "03", "06")),
            community("city-walks", "[ДЕМО] Городские прогулки", "Демонстрационные прогулки по известным местам Москвы в небольшой компании.", "community-walks.png", setOf("walks", "networking"), setOf("02", "04", "06")),
            community("online-club", "[ДЕМО] Онлайн-клуб встреч", "Демонстрационное сообщество для открытых онлайн-встреч без приватных ссылок в каталоге.", "community-online.png", setOf("online", "organizing", "networking"), setOf("01", "05", "06")),
        ),
        listOf(
            ManifestMeeting(key("meeting", "welcome"), "[ДЕМО] Знакомство с клубом", "Демонстрационная встреча для знакомства с приложением и участниками закрытой беты.", "${MEDIA_BASE}meeting-moscow.png", 7, LocalTime.of(19, 0), 120, "Москва, Тверская улица, 13", 55.7647, 37.6054, 40, false, null, key("user", "01"), key("community", "moscow-meets"), setOf("networking", "organizing").map { key("tag", it) }.toSet(), setOf("02", "03", "06").map { key("user", it) }.toSet()),
            ManifestMeeting(key("meeting", "organize-online"), "[ДЕМО] Как организовать онлайн-встречу", "Демонстрационный разбор подготовки понятной и безопасной онлайн-встречи.", "${MEDIA_BASE}meeting-online.png", 10, LocalTime.of(20, 0), 90, "Онлайн", 55.7558, 37.6176, 100, true, "https://api.whysoezzy.online/demo-events/organize-online", key("user", "05"), key("community", "online-club"), setOf("online", "organizing").map { key("tag", it) }.toSet(), setOf("01", "03", "06").map { key("user", it) }.toSet()),
            ManifestMeeting(key("meeting", "board-games"), "[ДЕМО] Вечер настольных игр", "Демонстрационный игровой вечер для небольшой компании и проверки записи на встречу.", "${MEDIA_BASE}meeting-moscow.png", 14, LocalTime.of(19, 30), 150, "Москва, улица Новый Арбат, 21", 55.7522, 37.5866, 36, false, null, key("user", "04"), key("community", "moscow-meets"), setOf("board-games", "networking").map { key("tag", it) }.toSet(), setOf("02", "05", "06").map { key("user", it) }.toSet()),
            ManifestMeeting(key("meeting", "vdnkh-walk"), "[ДЕМО] Прогулка по ВДНХ", "Демонстрационная прогулка по ВДНХ с понятной точкой сбора и ограниченной группой.", "${MEDIA_BASE}meeting-moscow.png", 21, LocalTime.of(11, 0), 120, "Москва, проспект Мира, 119", 55.8298, 37.6339, 30, false, null, key("user", "02"), key("community", "city-walks"), setOf("walks", "networking").map { key("tag", it) }.toSet(), setOf("01", "04", "06").map { key("user", it) }.toSet()),
            ManifestMeeting(key("meeting", "networking-online"), "[ДЕМО] Нетворкинг без неловкости", "Демонстрационная онлайн-встреча с короткими знакомствами и безопасным публичным описанием.", "${MEDIA_BASE}meeting-online.png", 24, LocalTime.of(20, 0), 90, "Онлайн", 55.7558, 37.6176, 100, true, "https://api.whysoezzy.online/demo-events/networking-online", key("user", "03"), key("community", "online-club"), setOf("online", "networking").map { key("tag", it) }.toSet(), setOf("01", "02", "05").map { key("user", it) }.toSet()),
            ManifestMeeting(key("meeting", "public-speaking"), "[ДЕМО] Практикум по публичным выступлениям", "Демонстрационный практикум с короткими выступлениями и бережной обратной связью.", "${MEDIA_BASE}meeting-moscow.png", 30, LocalTime.of(19, 0), 120, "Москва, улица Покровка, 47", 55.7641, 37.6527, 50, false, null, key("user", "03"), key("community", "moscow-meets"), setOf("public-speaking", "networking").map { key("tag", it) }.toSet(), setOf("01", "04", "06").map { key("user", it) }.toSet()),
        ),
        listOf(
            ManifestAdBlock(key("ad", "communities"), AdBlockType.COMMUNITIES, "[ДЕМО] Сообщества для старта", "Выберите демонстрационное сообщество и проверьте подписку в закрытой бете.", communities = setOf("moscow-meets", "city-walks", "online-club").map { key("community", it) }.toSet()),
            ManifestAdBlock(key("ad", "interests"), AdBlockType.TEXT, "[ДЕМО] Настройте интересы", "Выберите интересы, чтобы проверить персонализацию демонстрационного каталога.", "Выбрать интересы", "/profile/interests"),
            ManifestAdBlock(key("ad", "people"), AdBlockType.PEOPLE, "[ДЕМО] Люди со схожими интересами", "Откройте демонстрационные профили участников закрытой беты.", users = setOf("01", "02", "03", "05").map { key("user", it) }.toSet()),
        ),
    )
}
