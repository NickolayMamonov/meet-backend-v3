package dev.whysoezzy.meet.api

import dev.whysoezzy.meet.api.error.ApiErrorResponseWriter
import dev.whysoezzy.meet.api.error.PayloadTooLargeException
import dev.whysoezzy.meet.config.RealCatalogProperties
import jakarta.servlet.ReadListener
import jakarta.servlet.ServletInputStream
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletRequestWrapper
import jakarta.servlet.http.HttpServletResponse
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Component
import org.springframework.web.filter.OncePerRequestFilter

@Component
class RealCatalogRequestLimitFilter(
    private val properties: RealCatalogProperties,
    private val errorWriter: ApiErrorResponseWriter,
) : OncePerRequestFilter() {
    override fun shouldNotFilter(request: HttpServletRequest): Boolean =
        !request.requestURI.startsWith("/admin/real-catalog/")

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: jakarta.servlet.FilterChain,
    ) {
        if (request.contentLengthLong > properties.maxRequestBytes) {
            errorWriter.write(
                request,
                response,
                HttpStatus.PAYLOAD_TOO_LARGE,
                PayloadTooLargeException().message ?: "Request payload is too large",
                "PAYLOAD_TOO_LARGE",
            )
            return
        }
        try {
            filterChain.doFilter(LimitedRequest(request, properties.maxRequestBytes), response)
        } catch (exception: PayloadTooLargeException) {
            errorWriter.write(
                request,
                response,
                exception.status,
                exception.message ?: "Request payload is too large",
                exception.code,
            )
        }
    }

    private class LimitedRequest(
        request: HttpServletRequest,
        private val limit: Int,
    ) : HttpServletRequestWrapper(request) {
        override fun getInputStream(): ServletInputStream = LimitedInputStream(super.getInputStream(), limit)
    }

    private class LimitedInputStream(
        private val delegate: ServletInputStream,
        private val limit: Int,
    ) : ServletInputStream() {
        private var count = 0

        override fun read(): Int {
            val value = delegate.read()
            if (value >= 0) {
                count++
                if (count > limit) throw PayloadTooLargeException()
            }
            return value
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            val read = delegate.read(buffer, offset, length)
            if (read > 0) {
                count += read
                if (count > limit) throw PayloadTooLargeException()
            }
            return read
        }

        override fun isFinished(): Boolean = delegate.isFinished
        override fun isReady(): Boolean = delegate.isReady
        override fun setReadListener(readListener: ReadListener?) = delegate.setReadListener(readListener)
    }
}
