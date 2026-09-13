package dev.whysoezzy.meet.config

import com.google.auth.oauth2.ServiceAccountCredentials
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import dev.whysoezzy.meet.service.push.firebase.FirebasePushProvider
import dev.whysoezzy.meet.service.push.PushProvider
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.core.env.ConfigurableEnvironment
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

@Configuration(proxyBeanMethods = false)
class FirebasePushConfiguration {
    @Bean(destroyMethod = "close")
    @ConditionalOnProperty(
        prefix = "app.push",
        name = ["provider-enabled"],
        havingValue = "true",
    )
    @ConditionalOnMissingBean(PushProvider::class)
    fun firebasePushProvider(
        properties: PushProperties,
        environment: ConfigurableEnvironment,
    ): FirebasePushProvider {
        val settings = try {
            PushRuntimeSettings.from(properties)
        } catch (_: Throwable) {
            throw invalidConfiguration()
        }
        val logGuard = try {
            GoogleSdkLogGuard.install(environment)
        } catch (_: Throwable) {
            throw invalidConfiguration()
        }

        var app: FirebaseApp? = null
        try {
            val credentialsPath = Path.of(settings.credentialsFile)
            require(Files.isRegularFile(credentialsPath) && Files.isReadable(credentialsPath)) {
                throw invalidConfiguration()
            }
            val credentials = Files.newInputStream(credentialsPath).use { input ->
                ServiceAccountCredentials.fromStream(input)
            }
            require(credentials.projectId == PushRuntimeSettings.EXPECTED_PROJECT_ID) {
                throw invalidConfiguration()
            }
            val scopedCredentials = credentials
                .createScoped(listOf(FIREBASE_MESSAGING_SCOPE))
                .createWithCustomRetryStrategy(false)
            val options = FirebaseOptions.builder()
                .setCredentials(scopedCredentials)
                .setProjectId(PushRuntimeSettings.EXPECTED_PROJECT_ID)
                .setConnectTimeout(PushRuntimeSettings.FCM_CONNECT_TIMEOUT_MS)
                .setReadTimeout(PushRuntimeSettings.FCM_READ_TIMEOUT_MS)
                .setWriteTimeout(PushRuntimeSettings.FCM_WRITE_TIMEOUT_MS)
                .build()
            app = FirebaseApp.initializeApp(options, "meet-push-${UUID.randomUUID()}")
            return FirebasePushProvider(FirebaseMessaging.getInstance(app), app, logGuard)
        } catch (_: Throwable) {
            try {
                app?.delete()
            } catch (_: Throwable) {
                // Preserve the static configuration failure.
            }
            throw invalidConfiguration()
        }
    }

    private fun invalidConfiguration(): IllegalStateException =
        IllegalStateException(PushRuntimeSettings.INVALID_CONFIGURATION)

    private companion object {
        const val FIREBASE_MESSAGING_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
    }
}
