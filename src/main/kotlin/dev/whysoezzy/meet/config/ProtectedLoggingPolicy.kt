package dev.whysoezzy.meet.config

import org.springframework.core.env.ConfigurableEnvironment
import org.springframework.boot.context.properties.bind.Bindable
import org.springframework.boot.context.properties.bind.Binder
import org.springframework.core.ResolvableType

/**
 * Single source of truth for logger namespaces whose output can contain credentials,
 * FIDs, request payloads, or installation SQL bind values.
 */
object ProtectedLoggingPolicy {
    private val sdkNamespaces = listOf(
        "com.google.auth",
        "com.google.api.client",
        "com.google.firebase",
        "com.google.auth.http.HttpCredentialsAdapter",
        "org.apache.http",
        "org.apache.hc",
    )
    private val bindingNamespaces = listOf(
        "org.springframework.jdbc.core.StatementCreatorUtils",
        "org.hibernate.orm.jdbc.bind",
    )
    private val driverNamespaces = listOf("org.postgresql")

    fun validateEnvironment(environment: ConfigurableEnvironment) = validate(environment)

    fun validate(environment: ConfigurableEnvironment) {
        try {
            val groups = loggingGroups(environment)
            explicitLoggingLevels(environment).forEach { (loggerName, rawLevel) ->
                val targets = groups[loggerName].orEmpty().asSequence() + sequenceOf(loggerName)
                val targetList = targets.toList()
                when {
                    targetList.any(::isSdkNamespace) -> requireOff(rawLevel)
                    targetList.any(::isBindingNamespace) || targetList.any(::isDriverNamespace) ->
                        requireNoVerboseLevel(rawLevel)
                }
            }
        } catch (_: Throwable) {
            throw invalidConfiguration()
        }
    }

    fun isSdkNamespace(name: String): Boolean =
        sdkNamespaces.any { name == it || name.startsWith("$it.") }

    fun isBindingNamespace(name: String): Boolean =
        bindingNamespaces.any { name == it || name.startsWith("$it.") }

    fun isDriverNamespace(name: String): Boolean =
        driverNamespaces.any { name == it || name.startsWith("$it.") }

    fun invalidConfiguration(): IllegalStateException =
        IllegalStateException(PushRuntimeSettings.INVALID_CONFIGURATION)

    private fun requireOff(rawLevel: String) {
        require(rawLevel == "OFF")
    }

    private fun requireNoVerboseLevel(rawLevel: String) {
        require(rawLevel in setOf("OFF", "ERROR", "WARN", "INFO"))
    }

    private fun explicitLoggingLevels(environment: ConfigurableEnvironment): Map<String, String> {
        return requireNotNull(Binder.get(environment)
            .bind(
                "logging.level",
                Bindable.mapOf(String::class.java, String::class.java),
            )
            .orElse(emptyMap<String, String>()))
    }

    private fun loggingGroups(environment: ConfigurableEnvironment): Map<String, List<String>> {
        val listType = ResolvableType.forClassWithGenerics(List::class.java, String::class.java)
        val mapType = ResolvableType.forClassWithGenerics(
            Map::class.java,
            ResolvableType.forClass(String::class.java),
            listType,
        )
        @Suppress("UNCHECKED_CAST")
        val bound = Binder.get(environment)
            .bind("logging.group", Bindable.of(mapType))
            .orElse(emptyMap<String, List<String>>()) as Map<String, List<String>>
        return bound
    }

}
