package com.bvolpato.brutv.playback

import org.junit.Assert.*
import org.junit.Test

class RecoveryPolicyTest {
    @Test fun switchingOrStoppingInvalidatesPendingRecovery() {
        val policy = RecoveryPolicy()
        policy.startEntry()
        val old = policy.retry(FailureKind.NETWORK, 0.5)!!
        policy.startEntry()
        assertFalse(policy.isCurrent(old.generation))
        val current = policy.retry(FailureKind.TIMEOUT, 0.5)!!
        assertTrue(policy.isCurrent(current.generation))
        assertEquals(1, current.attempt)
        policy.stop()
        assertFalse(policy.isCurrent(current.generation))
        assertNull(policy.retry(FailureKind.NETWORK, 0.5))
    }

    @Test fun recoveryIsBoundedAndDoesNotRetryPermanentFailures() {
        val policy = RecoveryPolicy()
        policy.startEntry()
        for (kind in listOf(FailureKind.UNAUTHORIZED, FailureKind.NOT_FOUND, FailureKind.UNSUPPORTED, FailureKind.OTHER)) {
            assertNull(policy.retry(kind, 0.5))
        }
        assertEquals(listOf(750L, 1_500L, 3_000L, 6_000L),
            (1..4).map { policy.retry(FailureKind.SERVER, 0.5)!!.delayMs })
        assertNull(policy.retry(FailureKind.SERVER, 0.5))
        policy.healthy()
        assertEquals(1, policy.retry(FailureKind.NETWORK, 0.5)!!.attempt)
    }

    @Test fun liveWindowRecoveryAndJitterAreCapped() {
        val policy = RecoveryPolicy()
        policy.startEntry()
        assertEquals(0L, policy.retry(FailureKind.LIVE_WINDOW, 1.0)!!.delayMs)
        assertEquals(1_200L, policy.retry(FailureKind.NETWORK, -5.0)!!.delayMs)
        assertTrue(policy.retry(FailureKind.NETWORK, 5.0)!!.delayMs <= 8_000L)
    }

    @Test fun serverAndTimeoutResponsesRetryButMissingOrUnauthorizedContentDoesNot() {
        assertEquals(FailureKind.TIMEOUT, httpFailure(408))
        assertEquals(FailureKind.TIMEOUT, httpFailure(504))
        assertEquals(FailureKind.SERVER, httpFailure(503))
        for (status in listOf(401, 403, 404, 410, 429)) {
            assertFalse(httpFailure(status).retryable)
        }
    }

    @Test fun profilesKeepStartupAndMemoryWithinTheirBufferWindows() {
        for (profile in BufferProfile.entries) {
            val tuning = profile.tuning
            assertTrue(tuning.startBufferMs <= tuning.minBufferMs)
            assertTrue(tuning.rebufferMs <= tuning.minBufferMs)
            assertTrue(tuning.minBufferMs <= tuning.maxBufferMs)
            assertTrue(tuning.targetBytes <= 48 * 1024 * 1024)
            assertSame(profile, BufferProfile.fromKey(profile.key))
        }
        assertSame(BufferProfile.BALANCED, BufferProfile.fromKey("unknown"))
    }

    @Test fun onlyLowLatencyOverridesSourceLiveTiming() {
        assertNull(BufferProfile.BALANCED.tuning.liveOffsetMs)
        assertNull(BufferProfile.STABILITY.tuning.liveOffsetMs)
        assertEquals(2_000L, BufferProfile.LOW_LATENCY.tuning.liveOffsetMs ?: error("Missing low-latency override"))
    }
}
