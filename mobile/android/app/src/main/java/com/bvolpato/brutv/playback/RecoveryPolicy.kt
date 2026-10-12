package com.bvolpato.brutv.playback

internal enum class FailureKind {
    NETWORK, TIMEOUT, SERVER, LIVE_WINDOW, UNAUTHORIZED, NOT_FOUND, UNSUPPORTED, OTHER;

    val retryable: Boolean
        get() = this == NETWORK || this == TIMEOUT || this == SERVER || this == LIVE_WINDOW
}

internal data class RecoveryTicket(val generation: Long, val delayMs: Long, val attempt: Int)

internal fun httpFailure(status: Int): FailureKind = when (status) {
    401, 403 -> FailureKind.UNAUTHORIZED
    404, 410 -> FailureKind.NOT_FOUND
    408, 504 -> FailureKind.TIMEOUT
    in 500..599 -> FailureKind.SERVER
    else -> FailureKind.OTHER
}

/** A ticket belongs to one entry. Replacing or stopping the entry invalidates every old ticket. */
internal class RecoveryPolicy(private val maxRetries: Int = 4) {
    private var generation = 0L
    private var active = false
    private var attempts = 0

    fun startEntry(): Long {
        generation += 1
        active = true
        attempts = 0
        return generation
    }

    fun stop() {
        generation += 1
        active = false
        attempts = 0
    }

    fun isCurrent(token: Long): Boolean = active && token == generation

    fun healthy() {
        attempts = 0
    }

    fun retry(kind: FailureKind, jitter: Double): RecoveryTicket? {
        if (!active || !kind.retryable || attempts >= maxRetries) return null
        val attempt = ++attempts
        val base = (750L shl (attempt - 1)).coerceAtMost(6_000L)
        val delay = if (kind == FailureKind.LIVE_WINDOW && attempt == 1) 0L
        else (base * (0.8 + jitter.coerceIn(0.0, 1.0) * 0.4)).toLong().coerceAtMost(8_000L)
        return RecoveryTicket(generation, delay, attempt)
    }
}
