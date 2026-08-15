package dev.whysoezzy.meet.demo.catalog

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DemoCatalogScheduleCompilerTest {
    private val clock = Clock.fixed(Instant.parse("2026-08-15T00:00:00Z"), ZoneOffset.UTC)

    @Test
    fun `compiles deterministic Moscow values`() {
        val compiler = DemoCatalogScheduleCompiler(clock)
        val compiled = compiler.compile(
            BetaDemoCatalog.manifest,
            LocalDate.of(2099, 1, 1),
            Instant.parse("2098-12-01T00:00:00Z"),
        )
        val welcome = compiled.getValue(CatalogKey("closed-beta-demo/meeting/welcome"))
        assertEquals("08.01.2099", welcome.date)
        assertEquals(2 * 60 * 60 * 1000L, welcome.endsAt - welcome.time)
        assertTrue(compiled.values.all { it.time < it.endsAt })
        assertEquals(compiled, compiler.compile(BetaDemoCatalog.manifest, LocalDate.of(2099, 1, 1), Instant.parse("2098-12-01T00:00:00Z")))
    }

    @Test
    fun `rejects starts at or before validity boundary`() {
        assertThrows<IllegalArgumentException> {
            DemoCatalogScheduleCompiler(clock).compile(
                BetaDemoCatalog.manifest,
                LocalDate.of(2026, 8, 1),
                Instant.parse("2026-08-20T00:00:00Z"),
            )
        }
    }
}
