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
    private val jwtAuthFilter: JwtAuthFilter,
    private val adminKeyAuthFilter: AdminKeyAuthFilter,
    private val apiAuthenticationEntryPoint: ApiAuthenticationEntryPoint,
    private val apiAccessDeniedHandler: ApiAccessDeniedHandler,
) {

    @Bean
    fun securityFilterChain(http: HttpSecurity): SecurityFilterChain {
        http
            .csrf { it.disable() }
            .sessionManagement { it.sessionCreationPolicy(SessionCreationPolicy.STATELESS) }
            .exceptionHandling { exceptions ->
                exceptions
                    .authenticationEntryPoint(apiAuthenticationEntryPoint)
                    .accessDeniedHandler(apiAccessDeniedHandler)
            }
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
                    .requestMatchers("/admin/**").hasRole("ADMIN")

                    // Всё остальное — JWT обязателен
                    .anyRequest().authenticated()
            }
            .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter::class.java)
            .addFilterAfter(adminKeyAuthFilter, JwtAuthFilter::class.java)

        return http.build()
    }
}
