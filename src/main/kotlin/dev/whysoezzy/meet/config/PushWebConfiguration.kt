package dev.whysoezzy.meet.config

import dev.whysoezzy.meet.api.PushRequestMessageConverter
import org.springframework.context.annotation.Configuration
import org.springframework.http.converter.HttpMessageConverter
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer
import tools.jackson.databind.ObjectMapper

@Configuration
class PushWebConfiguration(
    private val objectMapper: ObjectMapper,
) : WebMvcConfigurer {
    override fun extendMessageConverters(converters: MutableList<HttpMessageConverter<*>>) {
        converters.add(0, PushRequestMessageConverter(objectMapper))
    }
}
