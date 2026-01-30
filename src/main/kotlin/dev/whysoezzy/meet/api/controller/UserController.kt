package dev.whysoezzy.meet.api.controller

import dev.whysoezzy.meet.api.dto.UserDto
import dev.whysoezzy.meet.service.UserService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.tags.Tag
import mu.KotlinLogging
import org.springframework.web.bind.annotation.*

private val logger = KotlinLogging.logger {}

@RestController
@Tag(name = "Users", description = "User management - Android compatible")
class UserController(
    private val userService: UserService
) {
    
    @GetMapping("/users/profile")
    @Operation(summary = "Get current user profile (mock user ID=1)")
    fun getCurrentUserProfile(): UserDto {
        logger.info { "GET /users/profile" }
        return userService.getUserById(1L) // Mock user
    }
    
    @GetMapping("/users/{id}")
    @Operation(summary = "Get user by ID")
    fun getUserById(@PathVariable id: Long): UserDto {
        logger.info { "GET /users/$id" }
        return userService.getUserById(id)
    }
}
