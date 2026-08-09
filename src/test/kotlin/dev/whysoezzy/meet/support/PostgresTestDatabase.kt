package dev.whysoezzy.meet.support

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.DriverManagerDataSource
import org.testcontainers.postgresql.PostgreSQLContainer
import java.util.UUID

class PostgresTestDatabase(
    schemaPrefix: String,
) : AutoCloseable {
    private val externalUrl = System.getenv("TEST_POSTGRES_JDBC_URL")?.takeIf(String::isNotBlank)
    private val schema = "${schemaPrefix}_${UUID.randomUUID().toString().replace("-", "")}"
    private val containerDelegate = lazy {
        try {
            PostgreSQLContainer("postgres:16-alpine").apply { start() }
        } catch (exception: Exception) {
            throw IllegalStateException(
                "PostgreSQL tests require Docker or TEST_POSTGRES_JDBC_URL with username and password",
                exception,
            )
        }
    }
    private val container by containerDelegate
    private val externalCredentials by lazy {
        val username = System.getenv("TEST_POSTGRES_USERNAME")?.takeIf(String::isNotBlank)
            ?: error("TEST_POSTGRES_USERNAME is required with TEST_POSTGRES_JDBC_URL")
        val password = System.getenv("TEST_POSTGRES_PASSWORD")
            ?: error("TEST_POSTGRES_PASSWORD is required with TEST_POSTGRES_JDBC_URL")
        DriverManagerDataSource(requireNotNull(externalUrl), username, password).also {
            JdbcTemplate(it).execute("CREATE SCHEMA $schema")
        }
        username to password
    }

    val jdbcUrl: String
        get() = externalUrl?.let {
            val separator = if ('?' in it) "&" else "?"
            "$it${separator}currentSchema=$schema"
        } ?: container.jdbcUrl

    val username: String
        get() = externalUrl?.let { externalCredentials.first } ?: container.username

    val password: String
        get() = externalUrl?.let { externalCredentials.second } ?: container.password

    fun dataSource(): DriverManagerDataSource =
        DriverManagerDataSource(jdbcUrl, username, password)

    override fun close() {
        if (externalUrl != null) {
            val (username, password) = externalCredentials
            JdbcTemplate(DriverManagerDataSource(externalUrl, username, password))
                .execute("DROP SCHEMA IF EXISTS $schema CASCADE")
        } else if (containerDelegate.isInitialized()) {
            container.stop()
        }
    }
}
