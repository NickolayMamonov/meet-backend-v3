package dev.whysoezzy.meet.domain.entity

import jakarta.persistence.*

@Entity
@Table(name = "tags")
class Tag(
    
    @Column(nullable = false, unique = true, length = 100)
    var text: String
    
) : BaseEntity()
