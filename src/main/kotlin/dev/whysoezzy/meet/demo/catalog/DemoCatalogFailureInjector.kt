package dev.whysoezzy.meet.demo.catalog

import org.springframework.stereotype.Component

fun interface DemoCatalogFailureInjector {
    fun afterFlushBeforeStateSave()
}

@Component
class NoopDemoCatalogFailureInjector : DemoCatalogFailureInjector {
    override fun afterFlushBeforeStateSave() = Unit
}
