package dev.whysoezzy.meet.demo.catalog

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component

@Component
class DemoCatalogAdvisoryLock(
    private val jdbcTemplate: JdbcTemplate,
) {
    fun tryAcquire(): Boolean =
        jdbcTemplate.queryForObject(
            "SELECT pg_try_advisory_xact_lock(?, ?)",
            Boolean::class.java,
            NAMESPACE_KEY,
            CATALOG_KEY,
        ) ?: false

    private companion object {
        // 0x4D454554 ("MEET") and 0x42455441 ("BETA"), signed PostgreSQL int32 values.
        const val NAMESPACE_KEY = 1_296_385_364
        const val CATALOG_KEY = 1_111_839_809
    }
}
