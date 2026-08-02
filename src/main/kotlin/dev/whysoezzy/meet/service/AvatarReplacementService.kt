package dev.whysoezzy.meet.service

import dev.whysoezzy.meet.api.error.NotFoundException
import dev.whysoezzy.meet.domain.repository.UserRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import org.springframework.transaction.support.TransactionSynchronization
import org.springframework.transaction.support.TransactionSynchronizationManager
import org.springframework.web.multipart.MultipartFile

@Service
class AvatarReplacementService(
    private val storageService: StorageService,
    private val userRepository: UserRepository,
) {
    @Transactional
    fun replace(userId: Long, file: MultipartFile): UploadResult {
        var uploaded: UploadResult? = null
        var updatedUser: dev.whysoezzy.meet.domain.entity.User? = null
        var userAvatarUrlBeforeReplacement: String? = null
        try {
            val newUpload = storageService.uploadAvatar(file, userId)
            uploaded = newUpload
            val user = userRepository.findWithLockById(userId)
                ?: throw NotFoundException("User not found")
            val oldUrl = user.avatarUrl
            updatedUser = user
            userAvatarUrlBeforeReplacement = oldUrl
            user.avatarUrl = newUpload.publicUrl
            userRepository.saveAndFlush(user)

            TransactionSynchronizationManager.registerSynchronization(object : TransactionSynchronization {
                override fun afterCommit() {
                    oldUrl?.let { storageService.deleteOwnedAvatarByUrl(it, userId) }
                }

                override fun afterCompletion(status: Int) {
                    if (status != TransactionSynchronization.STATUS_COMMITTED) {
                        storageService.deleteUploaded(newUpload)
                    }
                }
            })
            return newUpload
        } catch (e: Exception) {
            updatedUser?.avatarUrl = userAvatarUrlBeforeReplacement
            uploaded?.let(storageService::deleteUploaded)
            throw e
        }
    }
}
