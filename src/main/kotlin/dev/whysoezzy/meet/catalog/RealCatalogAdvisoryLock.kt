package dev.whysoezzy.meet.catalog

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component

@Component
class RealCatalogAdvisoryLock(
    private val jdbcTemplate: JdbcTemplate,
) {
    fun tryAcquire(): Boolean {
        jdbcTemplate.execute("SET LOCAL lock_timeout = '5s'")
        return jdbcTemplate.queryForObject(
            "SELECT pg_try_advisory_xact_lock(?, ?)",
            Boolean::class.java,
            1_296_385_364,
            1_112_364_738,
        ) ?: false
    }
}
