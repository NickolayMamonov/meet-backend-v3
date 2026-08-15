package dev.whysoezzy.meet.demo.catalog

import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface DemoCatalogStateRepository : JpaRepository<DemoCatalogState, String>
