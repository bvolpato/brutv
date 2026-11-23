package com.bvolpato.brutv.playback

import android.net.testUri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.ParserException
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import com.sun.net.httpserver.HttpServer
import okhttp3.ConnectionPool
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.security.cert.CertificateException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLKeyException
import javax.net.ssl.SSLPeerUnverifiedException

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
        assertEquals(
            listOf(750L, 1_500L, 3_000L, 6_000L),
            (1..4).map { policy.retry(FailureKind.SERVER, 0.5)!!.delayMs },
        )
        assertNull(policy.retry(FailureKind.SERVER, 0.5))
        policy.healthy()
        assertEquals(1, policy.retry(FailureKind.NETWORK, 0.5)!!.attempt)
    }

    @Test fun liveRecoveryAllowsSixRetriesUpToTenSecondsAndSupportsBoundedOverride() {
        val policy = RecoveryPolicy()
        policy.startEntry(isLive = true)
        val delays = (1..6).map { policy.retry(FailureKind.SERVER, 0.5)!!.delayMs }
        assertEquals(listOf(750L, 1_500L, 3_000L, 6_000L, 10_000L, 10_000L), delays)
        assertNull(policy.retry(FailureKind.SERVER, 0.5))

        policy.healthy()
        assertTrue(policy.retry(FailureKind.RATE_LIMITED, 1.0)!!.delayMs <= 10_000L)
        assertNotNull(policy.retry(FailureKind.UNAUTHORIZED, 0.5, allowTemporaryOverride = true))
        assertNotNull(policy.retry(FailureKind.NOT_FOUND, 0.5, allowTemporaryOverride = true))
    }

    @Test fun liveWindowRecoveryAndJitterAreCapped() {
        val policy = RecoveryPolicy()
        policy.startEntry()
        assertEquals(0L, policy.retry(FailureKind.LIVE_WINDOW, 1.0)!!.delayMs)
        assertEquals(1_200L, policy.retry(FailureKind.NETWORK, -5.0)!!.delayMs)
        assertTrue(policy.retry(FailureKind.NETWORK, 5.0)!!.delayMs <= 8_000L)
    }

    @Test fun serverTimeoutAndRateLimitResponsesRetryButMissingOrUnauthorizedContentDoesNot() {
        assertEquals(FailureKind.TIMEOUT, httpFailure(408))
        assertEquals(FailureKind.TIMEOUT, httpFailure(504))
        assertEquals(FailureKind.RATE_LIMITED, httpFailure(429))
        assertEquals(FailureKind.RATE_LIMITED, httpFailure(458))
        assertTrue(httpFailure(429).retryable)
        assertTrue(httpFailure(458).retryable)
        for (status in listOf(500, 502, 503, 520, 521, 522, 524, 526)) {
            assertEquals(FailureKind.SERVER, httpFailure(status))
            assertTrue(httpFailure(status).retryable)
        }
        for (status in listOf(401, 403, 404, 410)) {
            assertFalse(httpFailure(status).retryable)
        }
    }

    @OptIn(UnstableApi::class)
    @Test fun classifiesTransientSslAndEofAsRetryableButRejectsCertificateErrors() {
        assertEquals(FailureKind.OTHER, classifyFailure(listOf(SSLPeerUnverifiedException("hostname mismatch")), 0))
        assertEquals(FailureKind.OTHER, classifyFailure(listOf(SSLKeyException("bad key")), 0))
        assertEquals(
            FailureKind.OTHER,
            classifyFailure(listOf(SSLHandshakeException("cert failed"), CertificateException("untrusted")), 0),
        )
        assertEquals(FailureKind.OTHER, classifyFailure(listOf(SSLHandshakeException("protocol error")), 0))

        assertEquals(FailureKind.NETWORK, classifyFailure(listOf(SSLException("Connection reset by peer")), 0))
        assertEquals(
            FailureKind.TIMEOUT,
            classifyFailure(listOf(SSLHandshakeException("timeout"), SocketTimeoutException("read timed out")), 0),
        )
        assertEquals(
            FailureKind.NETWORK,
            classifyFailure(listOf(SSLHandshakeException("eof"), EOFException("closed")), 0),
        )
        assertEquals(FailureKind.NETWORK, classifyFailure(listOf(EOFException("unexpected eof")), 0))
        assertEquals(FailureKind.NETWORK, classifyFailure(listOf(SocketException("broken pipe")), 0))
        assertEquals(FailureKind.TIMEOUT, classifyFailure(listOf(SocketTimeoutException("read timed out")), 0))
    }

    @OptIn(UnstableApi::class)
    @Test fun streamLoadErrorPolicyRetriesTransientErrorsFailsFastOnAuthAndAllowsMultiVariantFallback() {
        val policy = StreamLoadErrorHandlingPolicy()
        assertEquals(2, policy.getMinimumLoadableRetryCount(C.DATA_TYPE_MEDIA))

        for (code in listOf(401, 403, 404, 410)) {
            assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(loadErrorInfo(httpError(code), errorCount = 1)))
        }
        for (code in listOf(408, 429, 458, 500, 503, 522, 524)) {
            assertEquals(400L, policy.getRetryDelayMsFor(loadErrorInfo(httpError(code), errorCount = 1)))
            assertEquals(1_000L, policy.getRetryDelayMsFor(loadErrorInfo(httpError(code), errorCount = 2)))
            assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(loadErrorInfo(httpError(code), errorCount = 3)))
        }
        assertEquals(400L, policy.getRetryDelayMsFor(loadErrorInfo(SocketTimeoutException("timeout"), errorCount = 1)))
        assertEquals(1_000L, policy.getRetryDelayMsFor(loadErrorInfo(SSLException("Connection reset"), errorCount = 2)))
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(loadErrorInfo(SSLPeerUnverifiedException("bad host"), errorCount = 1)))
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(loadErrorInfo(SSLHandshakeException("cert"), errorCount = 1)))
        assertEquals(
            C.TIME_UNSET,
            policy.getRetryDelayMsFor(loadErrorInfo(ParserException.createForMalformedManifest("bad", null), errorCount = 1)),
        )

        val multiTrack = LoadErrorHandlingPolicy.FallbackOptions(1, 0, 2, 0, false)
        val singleTrack = LoadErrorHandlingPolicy.FallbackOptions(1, 0, 1, 0, false)
        assertNotNull(policy.getFallbackSelectionFor(multiTrack, loadErrorInfo(httpError(522), errorCount = 1)))
        assertNotNull(policy.getFallbackSelectionFor(multiTrack, loadErrorInfo(httpError(429), errorCount = 1)))
        assertNotNull(policy.getFallbackSelectionFor(multiTrack, loadErrorInfo(httpError(404), errorCount = 1)))
        assertNull(policy.getFallbackSelectionFor(multiTrack, loadErrorInfo(httpError(401), errorCount = 1)))
        assertNull(policy.getFallbackSelectionFor(singleTrack, loadErrorInfo(httpError(522), errorCount = 1)))
    }

    @Test fun playbackHttpClientFollowsSslRedirectsAndStripsCrossOriginSensitiveHeaders() {
        val pool = ConnectionPool(2, 10, TimeUnit.SECONDS)
        val baseClient = createPlaybackHttpClient(pool)
        assertTrue(baseClient.followRedirects)
        assertTrue(baseClient.followSslRedirects)

        val capturedSame = AtomicReference<Map<String, List<String>>>()
        val capturedCross = AtomicReference<Map<String, List<String>>>()
        val targetServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/") { exchange ->
                capturedCross.set(exchange.requestHeaders.toMap())
                exchange.sendResponseHeaders(200, 2)
                exchange.responseBody.use { it.write(byteArrayOf(1, 2)) }
                exchange.close()
            }
            start()
        }
        val originServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/same") { exchange ->
                capturedSame.set(exchange.requestHeaders.toMap())
                exchange.sendResponseHeaders(200, 2)
                exchange.responseBody.use { it.write(byteArrayOf(3, 4)) }
                exchange.close()
            }
            createContext("/redirect") { exchange ->
                exchange.responseHeaders.add("Location", "http://127.0.0.1:${targetServer.address.port}/edge.ts")
                exchange.sendResponseHeaders(302, -1)
                exchange.close()
            }
            start()
        }
        try {
            val originUrl = "http://127.0.0.1:${originServer.address.port}/redirect".toHttpUrl()
            val customHeaders = mapOf(
                "Authorization" to "Bearer secret",
                "Cookie" to "sid=secret",
                "Referer" to "https://panel.example/watch",
                "X-Provider-Secret" to "secret-value",
                "User-Agent" to "BruTV/1.0",
            )
            val guarded = baseClient.newBuilder()
                .addNetworkInterceptor(CrossOriginHeaderStripInterceptor(originUrl, customHeaders.keys))
                .build()

            fun execute(path: String) {
                val req = Request.Builder().url("http://127.0.0.1:${originServer.address.port}$path").apply {
                    customHeaders.forEach { (k, v) -> header(k, v) }
                }.build()
                guarded.newCall(req).execute().use { assertEquals(200, it.code) }
            }

            execute("/same")
            val sameNames = capturedSame.get().keys.map(String::lowercase)
            assertTrue("authorization" in sameNames)
            assertTrue("cookie" in sameNames)
            assertTrue("referer" in sameNames)
            assertTrue("x-provider-secret" in sameNames)

            execute("/redirect")
            val crossNames = capturedCross.get().keys.map(String::lowercase)
            assertFalse("authorization" in crossNames)
            assertFalse("cookie" in crossNames)
            assertFalse("referer" in crossNames)
            assertFalse("x-provider-secret" in crossNames)
            assertEquals(
                listOf("BruTV/1.0"),
                capturedCross.get().entries.first { it.key.equals("User-Agent", ignoreCase = true) }.value,
            )
        } finally {
            pool.evictAll()
            originServer.stop(0)
            targetServer.stop(0)
        }
    }

    @Test fun profilesKeepStartupAndMemoryWithinTheirBufferWindows() {
        for (profile in BufferProfile.entries) {
            val tuning = profile.tuning
            assertTrue(tuning.startBufferMs <= tuning.minBufferMs)
            assertTrue(tuning.rebufferMs <= tuning.minBufferMs)
            assertTrue(tuning.minBufferMs <= tuning.maxBufferMs)
            assertTrue(tuning.targetBytes <= 48 * 1024 * 1024)
            assertEquals(tuning.targetBytes, tuning.effectiveTargetBytes(isLowRamDevice = false))
            assertTrue(tuning.effectiveTargetBytes(isLowRamDevice = true) < tuning.targetBytes)
            assertTrue(tuning.effectiveTargetBytes(isLowRamDevice = true) >= 12 * 1024 * 1024)
            assertSame(profile, BufferProfile.fromKey(profile.key))
        }
        assertSame(BufferProfile.BALANCED, BufferProfile.fromKey("unknown"))
        val balanced = BufferProfile.BALANCED.tuning
        assertEquals(6_000, balanced.minBufferMs)
        assertEquals(20_000, balanced.maxBufferMs)
        assertEquals(1_500, balanced.startBufferMs)
        assertEquals(3_000, balanced.rebufferMs)
        assertEquals(16 * 1024 * 1024, balanced.effectiveTargetBytes(isLowRamDevice = true))
    }

    @Test fun onlyLowLatencyOverridesSourceLiveTiming() {
        assertNull(BufferProfile.BALANCED.tuning.liveOffsetMs)
        assertNull(BufferProfile.STABILITY.tuning.liveOffsetMs)
        assertEquals(2_000L, BufferProfile.LOW_LATENCY.tuning.liveOffsetMs ?: error("Missing low-latency override"))
    }

    @Test fun networkRecoveryPolicyIgnoresInitialStateRecoversOnRestoreOrSwitchAndDebounces() {
        val policy = NetworkRecoveryPolicy(debounceMs = 2_000L)

        // Initial callback does not trigger recovery.
        assertFalse(policy.onAvailable(networkId = 100L, nowElapsedMs = 500L))
        // Repeated callback for the same active network does not trigger recovery.
        assertFalse(policy.onAvailable(networkId = 100L, nowElapsedMs = 5_000L))

        // Losing an unrelated network does not mark the active network unavailable.
        policy.onLost(networkId = 999L)
        assertFalse(policy.onAvailable(networkId = 100L, nowElapsedMs = 6_000L))

        // Losing and restoring the active network triggers recovery.
        policy.onLost(networkId = 100L)
        assertTrue(policy.onAvailable(networkId = 100L, nowElapsedMs = 7_000L))

        // Interface switch inside debounce window is suppressed, but switches after debounce trigger recovery.
        assertFalse(policy.onAvailable(networkId = 200L, nowElapsedMs = 8_500L))
        assertTrue(policy.onAvailable(networkId = 300L, nowElapsedMs = 9_000L))

        // Subsequent loss + restore within debounce window is suppressed until debounce elapses.
        policy.onLost(networkId = 300L)
        assertFalse(policy.onAvailable(networkId = 300L, nowElapsedMs = 10_999L))
        policy.onLost(networkId = 300L)
        assertTrue(policy.onAvailable(networkId = 300L, nowElapsedMs = 11_000L))
    }

    @OptIn(UnstableApi::class)
    private fun httpError(code: Int): HttpDataSource.InvalidResponseCodeException =
        HttpDataSource.InvalidResponseCodeException(
            code,
            "HTTP $code",
            null,
            emptyMap(),
            DataSpec(testUri()),
            ByteArray(0),
        )

    @OptIn(UnstableApi::class)
    private fun loadErrorInfo(error: IOException, errorCount: Int): LoadErrorHandlingPolicy.LoadErrorInfo {
        val uri = testUri()
        return LoadErrorHandlingPolicy.LoadErrorInfo(
            LoadEventInfo(1L, DataSpec(uri), uri, emptyMap(), 0L, 0L, 0L),
            MediaLoadData(C.DATA_TYPE_MEDIA),
            error,
            errorCount,
        )
    }
}
