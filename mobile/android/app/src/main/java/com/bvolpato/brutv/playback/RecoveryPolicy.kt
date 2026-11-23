package com.bvolpato.brutv.playback

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.ParserException
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.Loader
import okhttp3.ConnectionPool
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.EOFException
import java.io.FileNotFoundException
import java.io.IOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLKeyException
import javax.net.ssl.SSLPeerUnverifiedException

internal enum class FailureKind {
    NETWORK, TIMEOUT, SERVER, RATE_LIMITED, LIVE_WINDOW, UNAUTHORIZED, NOT_FOUND, UNSUPPORTED, OTHER;

    val retryable: Boolean
        get() = this == NETWORK ||
            this == TIMEOUT ||
            this == SERVER ||
            this == RATE_LIMITED ||
            this == LIVE_WINDOW
}

internal data class RecoveryTicket(val generation: Long, val delayMs: Long, val attempt: Int)

internal fun httpFailure(status: Int): FailureKind = when (status) {
    401, 403 -> FailureKind.UNAUTHORIZED
    404, 410 -> FailureKind.NOT_FOUND
    408, 504 -> FailureKind.TIMEOUT
    429, 458 -> FailureKind.RATE_LIMITED
    in 500..599 -> FailureKind.SERVER
    else -> FailureKind.OTHER
}

/** A ticket belongs to one entry. Replacing or stopping the entry invalidates every old ticket. */
internal class RecoveryPolicy(
    private val defaultMaxRetries: Int = 4,
    private val liveMaxRetries: Int = 6,
) {
    private var generation = 0L
    private var active = false
    private var attempts = 0
    private var currentMaxRetries = defaultMaxRetries
    private var currentBaseCapMs = 6_000L
    private var currentDelayCapMs = 8_000L

    fun startEntry(isLive: Boolean = false): Long {
        generation += 1
        active = true
        attempts = 0
        currentMaxRetries = if (isLive) liveMaxRetries else defaultMaxRetries
        currentBaseCapMs = if (isLive) 10_000L else 6_000L
        currentDelayCapMs = if (isLive) 10_000L else 8_000L
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

    fun retry(kind: FailureKind, jitter: Double, allowTemporaryOverride: Boolean = false): RecoveryTicket? {
        if (!active || (!kind.retryable && !allowTemporaryOverride) || attempts >= currentMaxRetries) return null
        val attempt = ++attempts
        val base = (750L shl (attempt - 1)).coerceAtMost(currentBaseCapMs)
        val delay = if (kind == FailureKind.LIVE_WINDOW && attempt == 1) 0L
        else (base * (0.8 + jitter.coerceIn(0.0, 1.0) * 0.4)).toLong().coerceAtMost(currentDelayCapMs)
        return RecoveryTicket(generation, delay, attempt)
    }
}

/**
 * Pure state machine deciding when network availability/interface transitions should trigger
 * an immediate playback reconnect while ignoring initial registration callbacks and rapid flaps.
 */
internal class NetworkRecoveryPolicy(
    private val debounceMs: Long = DEFAULT_DEBOUNCE_MS,
) {
    private var initialized = false
    private var wasAvailable = false
    private var lastNetworkId: Long? = null
    private var lastRecoveryElapsedMs: Long? = null

    fun onAvailable(networkId: Long, nowElapsedMs: Long): Boolean {
        if (!initialized) {
            initialized = true
            wasAvailable = true
            lastNetworkId = networkId
            return false
        }
        val transitionedFromLost = !wasAvailable
        val switchedNetwork = lastNetworkId != null && networkId != lastNetworkId
        wasAvailable = true
        lastNetworkId = networkId
        if (!transitionedFromLost && !switchedNetwork) return false
        val previousRecovery = lastRecoveryElapsedMs
        if (previousRecovery != null && nowElapsedMs - previousRecovery < debounceMs) {
            return false
        }
        lastRecoveryElapsedMs = nowElapsedMs
        return true
    }

    fun onLost(networkId: Long) {
        if (!initialized) {
            initialized = true
            wasAvailable = false
            return
        }
        if (lastNetworkId == null || networkId == lastNetworkId) {
            wasAvailable = false
        }
    }

    companion object {
        const val DEFAULT_DEBOUNCE_MS = 2_000L
    }
}

internal fun isNonRetryableSslFailure(causes: List<Throwable>): Boolean {
    if (causes.any {
            it is SSLPeerUnverifiedException ||
                it is SSLKeyException ||
                it is CertificateException ||
                it is CertPathValidatorException
        }
    ) {
        return true
    }
    if (causes.any { it is SSLHandshakeException }) {
        val hasTransientNetworkCause = causes.any {
            it is SocketTimeoutException || it is SocketException || it is EOFException
        }
        return !hasTransientNetworkCause
    }
    return false
}

@OptIn(UnstableApi::class)
internal fun extractHttpStatusCode(error: Throwable): Int? =
    generateSequence<Throwable>(error) { it.cause }
        .take(12)
        .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
        .firstOrNull()
        ?.responseCode

@OptIn(UnstableApi::class)
internal fun classifyFailure(causes: List<Throwable>, errorCode: Int): FailureKind {
    val response = causes.filterIsInstance<HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
    if (response != null) return httpFailure(response)
    if (isNonRetryableSslFailure(causes)) return FailureKind.OTHER
    if (causes.any { it is SocketTimeoutException }) return FailureKind.TIMEOUT
    if (causes.any { it is SSLException }) return FailureKind.NETWORK
    if (causes.any { it is SocketException || it is UnknownHostException || it is EOFException }) return FailureKind.NETWORK
    return when (errorCode) {
        PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW -> FailureKind.LIVE_WINDOW
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED -> FailureKind.NETWORK
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> FailureKind.TIMEOUT
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> FailureKind.NOT_FOUND
        PlaybackException.ERROR_CODE_IO_NO_PERMISSION -> FailureKind.UNAUTHORIZED
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED -> FailureKind.UNSUPPORTED
        else -> FailureKind.OTHER
    }
}

/**
 * Allows up to 2 fast internal segment/manifest retries for transient network, timeout, rate-limit,
 * and 5xx errors and preserves default multi-variant HLS fallback, while failing fast on 401/403/404/410
 * and certificate errors so outer controller recovery and `.m3u8 <-> .ts` fallback can take over.
 */
@OptIn(UnstableApi::class)
internal class StreamLoadErrorHandlingPolicy : DefaultLoadErrorHandlingPolicy(MAX_INTERNAL_RETRIES) {
    override fun getMinimumLoadableRetryCount(dataType: Int): Int = MAX_INTERNAL_RETRIES

    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        if (loadErrorInfo.errorCount > MAX_INTERNAL_RETRIES) return C.TIME_UNSET
        val exception = loadErrorInfo.exception
        if (exception is ParserException ||
            exception is FileNotFoundException ||
            exception is HttpDataSource.CleartextNotPermittedException ||
            exception is Loader.UnexpectedLoaderException
        ) {
            return C.TIME_UNSET
        }
        val causes = generateSequence<Throwable>(exception) { it.cause }.take(12).toList()
        val responseCode = causes.filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
            .firstOrNull()?.responseCode
        if (responseCode != null) {
            val retryableStatus = responseCode == 408 ||
                responseCode == 429 ||
                responseCode == 458 ||
                responseCode in 500..599
            return if (retryableStatus) retryDelayForAttempt(loadErrorInfo.errorCount) else C.TIME_UNSET
        }
        if (isNonRetryableSslFailure(causes)) return C.TIME_UNSET
        return retryDelayForAttempt(loadErrorInfo.errorCount)
    }

    override fun getFallbackSelectionFor(
        fallbackOptions: LoadErrorHandlingPolicy.FallbackOptions,
        loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo,
    ): LoadErrorHandlingPolicy.FallbackSelection? {
        val statusCode = extractHttpStatusCode(loadErrorInfo.exception)
        if (statusCode == 401) return null
        val defaultSelection = super.getFallbackSelectionFor(fallbackOptions, loadErrorInfo)
        if (defaultSelection != null) return defaultSelection
        val fallbackEligible = statusCode != null && (statusCode == 429 || statusCode == 458 || statusCode in 500..599)
        if (!fallbackEligible) return null
        return when {
            fallbackOptions.isFallbackAvailable(FALLBACK_TYPE_LOCATION) ->
                LoadErrorHandlingPolicy.FallbackSelection(FALLBACK_TYPE_LOCATION, DEFAULT_LOCATION_EXCLUSION_MS)
            fallbackOptions.isFallbackAvailable(FALLBACK_TYPE_TRACK) ->
                LoadErrorHandlingPolicy.FallbackSelection(FALLBACK_TYPE_TRACK, DEFAULT_TRACK_EXCLUSION_MS)
            else -> null
        }
    }

    private fun retryDelayForAttempt(errorCount: Int): Long =
        if (errorCount <= 1) FIRST_RETRY_DELAY_MS else SECOND_RETRY_DELAY_MS

    companion object {
        const val MAX_INTERNAL_RETRIES = 2
        const val FIRST_RETRY_DELAY_MS = 400L
        const val SECOND_RETRY_DELAY_MS = 1_000L
    }
}

/**
 * Strips sensitive non-User-Agent headers whenever a request redirects or resolves to a different
 * origin (`scheme`, `host`, or `port`) than the original stream URL.
 */
internal class CrossOriginHeaderStripInterceptor(
    private val sourceOrigin: HttpUrl,
    private val guardedHeaderNames: Set<String> = emptySet(),
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val actual = request.url
        val sameOrigin = actual.scheme == sourceOrigin.scheme &&
            actual.host == sourceOrigin.host &&
            actual.port == sourceOrigin.port
        if (sameOrigin) return chain.proceed(request)
        val sanitized = request.newBuilder().apply {
            for (name in guardedHeaderNames) {
                if (!name.equals("User-Agent", ignoreCase = true)) {
                    removeHeader(name)
                }
            }
            for (name in ALWAYS_STRIPPED_HEADERS) {
                removeHeader(name)
            }
        }.build()
        return chain.proceed(sanitized)
    }

    companion object {
        private val ALWAYS_STRIPPED_HEADERS = setOf("Authorization", "Cookie", "Proxy-Authorization")
    }
}

internal fun createPlaybackHttpClient(connectionPool: ConnectionPool): OkHttpClient =
    OkHttpClient.Builder()
        .connectionPool(connectionPool)
        .followRedirects(true)
        .followSslRedirects(true)
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()
