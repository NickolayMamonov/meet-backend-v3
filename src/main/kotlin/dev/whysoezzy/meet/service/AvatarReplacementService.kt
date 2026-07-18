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
        try {
            val newUpload = storageService.uploadAvatar(file, userId)
            uploaded = newUpload
            val user = userRepository.findWithLockById(userId)
                ?: throw NotFoundException("User not found")
            val oldUrl = user.avatarUrl
            user.avatarUrl = newUpload.publicUrl
            userRepository.saveAndFlush(user)

            TransactionSynchronizationManager.registerSynchronization(object : TransactionSynchronization {
                override fun afterCommit() {
                    if (oldUrl != null && storageService.isManagedUrl(oldUrl)) {
                        storageService.deleteByUrl(oldUrl)
                    }
                }

                override fun afterCompletion(status: Int) {
                    if (status != TransactionSynchronization.STATUS_COMMITTED) {
                        storageService.deleteByUrl(newUpload.publicUrl)
                    }
                }
            })
            return newUpload
        } catch (e: Exception) {
            uploaded?.let { storageService.deleteByUrl(it.publicUrl) }
            throw e
        }
    }
}
