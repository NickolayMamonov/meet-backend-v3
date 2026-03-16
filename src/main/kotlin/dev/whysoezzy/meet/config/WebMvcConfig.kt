package dev.whysoezzy.meet.config

import org.springframework.context.annotation.Configuration
import org.springframework.web.servlet.config.annotation.ResourceHandlerRegistry
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer
import java.nio.file.Paths

@Configuration
class WebMvcConfig(
    private val storageProperties: StorageProperties
) : WebMvcConfigurer {


    /* Маппинг GET /media/ → файловая система ./uploads/
     *
     * После загрузки аватарки по URL вида:
     *   http://localhost:8080/media/avatars/abc123.jpg
     * Spring будет отдавать файл из:
     *   ./uploads/avatars/abc123.jpg
     */
    override fun addResourceHandlers(registry: ResourceHandlerRegistry) {
        val uploadPath = Paths.get(storageProperties.uploadDir)
            .toAbsolutePath()
            .normalize()
            .toString()

        registry
            .addResourceHandler("/media/**")
            .addResourceLocations("file:$uploadPath/")
            .setCachePeriod(3600) // 1 час кэша для статики
    }
}
