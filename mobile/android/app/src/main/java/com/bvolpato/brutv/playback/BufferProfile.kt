package com.bvolpato.brutv.playback

enum class BufferProfile(
    val key: String,
    val title: String,
    val description: String,
    internal val tuning: BufferTuning,
) {
    LOW_LATENCY(
        "ultra_low", "Ultra low latency", "Lower delay with less buffering room. Use for reliable low-latency sources; it may rebuffer more.",
        BufferTuning(1_500, 5_000, 500, 1_000, 2_000, 24 * 1024 * 1024),
    ),
    BALANCED(
        "balanced", "Balanced", "Fast start with room for normal network jitter.",
        BufferTuning(4_000, 12_000, 1_000, 2_000, null, 32 * 1024 * 1024),
    ),
    STABILITY(
        "high_stability", "High stability", "A deeper buffer for a fluctuating connection.",
        BufferTuning(10_000, 30_000, 2_000, 4_000, null, 48 * 1024 * 1024),
    );

    companion object {
        fun fromKey(key: String): BufferProfile = entries.firstOrNull { it.key == key } ?: BALANCED
    }
}

internal data class BufferTuning(
    val minBufferMs: Int,
    val maxBufferMs: Int,
    val startBufferMs: Int,
    val rebufferMs: Int,
    val liveOffsetMs: Long?,
    val targetBytes: Int,
)
