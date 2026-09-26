package dev.whysoezzy.meet.catalog

import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface RealCatalogStateRepository : JpaRepository<RealCatalogStateEntity, String>

@Repository
interface RealCatalogRevisionRepository : JpaRepository<RealCatalogRevisionEntity, String> {
    fun findByCatalogKeyAndRevisionLabel(catalogKey: String, revisionLabel: String): RealCatalogRevisionEntity?
}
