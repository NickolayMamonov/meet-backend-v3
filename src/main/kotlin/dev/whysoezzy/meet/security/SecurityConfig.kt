package dev.whysoezzy.meet.security

import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.http.HttpMethod
import org.springframework.security.config.annotation.web.builders.HttpSecurity
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity
import org.springframework.security.config.http.SessionCreationPolicy
import org.springframework.security.web.SecurityFilterChain
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter

@Configuration
@EnableWebSecurity
class SecurityConfig(
    private val jwtAuthFilter: JwtAuthFilter
) {

    @Bean
    fun securityFilterChain(http: HttpSecurity): SecurityFilterChain {
        http
            .csrf { it.disable() }
            .sessionManagement { it.sessionCreationPolicy(SessionCreationPolicy.STATELESS) }
            .authorizeHttpRequests { auth ->
                auth
                    // Auth — полностью публичный
                    .requestMatchers("/auth/**").permitAll()

                    // Swagger / OpenAPI
                    .requestMatchers(
                        "/swagger-ui/**",
                        "/swagger-ui.html",
                        "/api-docs/**",
                        "/v3/api-docs/**"
                    ).permitAll()

                    // Статика — GET /media/** отдаётся без токена
                    .requestMatchers(HttpMethod.GET, "/media/**").permitAll()

                    // Загрузка файлов — требует авторизации (POST /media/**)
                    .requestMatchers(HttpMethod.POST, "/media/**").authenticated()

                    // Публичный просмотр контента
                    .requestMatchers(HttpMethod.GET, "/meetings/**").permitAll()
                    .requestMatchers(HttpMethod.GET, "/communities/**").permitAll()
                    .requestMatchers(HttpMethod.GET, "/tags/**").permitAll()
                    .requestMatchers(HttpMethod.GET, "/api/v1/tags").permitAll()
                    // AdBlocks — контроллер маппится на /api/ads (не /ad-blocks)
                    .requestMatchers(HttpMethod.GET, "/api/ads/**").permitAll()
                    // Admin-эндпоинты: на уровне Spring Security открыты,
                    // доступ гейтится заголовком X-Admin-Key в контроллере (интерим, до ролей)
                    .requestMatchers("/admin/**").permitAll()

                    // Всё остальное — JWT обязателен
                    .anyRequest().authenticated()
            }
            .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter::class.java)

        return http.build()
    }
}
