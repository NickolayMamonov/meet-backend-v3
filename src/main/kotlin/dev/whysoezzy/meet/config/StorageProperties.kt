package dev.whysoezzy.meet.config

import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.context.annotation.Configuration

@Configuration
@ConfigurationProperties(prefix = "app.storage")
class StorageProperties {

    /** Директория для хранения загружаемых файлов */
    var uploadDir: String = "./uploads"

    /** Публичный базовый URL, по которому файлы доступны снаружи */
    var baseUrl: String = "http://localhost:8080/media"

    /** Максимальный размер файла в байтах (default 5 MB) */
    var maxFileSize: Long = 5_242_880L

    /**
     * Разрешённые MIME-типы через запятую.
     * Например: "image/jpeg,image/png,image/webp"
     */
    var allowedTypes: String = "image/jpeg,image/png,image/webp"

    /** Получить разрешённые типы как Set для быстрой проверки */
    fun allowedTypesSet(): Set<String> =
        allowedTypes.split(",").map { it.trim() }.toSet()
}
