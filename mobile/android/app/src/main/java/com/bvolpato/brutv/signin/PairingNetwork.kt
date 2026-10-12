package com.bvolpato.brutv.signin

import com.bvolpato.brutv.data.SourceConfig
import java.io.BufferedInputStream
import java.io.Closeable
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

internal class PairingReceiver private constructor(
    val invite: PairingInvite,
    keys: java.security.KeyPair,
    private val server: ServerSocket,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val session = PairingSession(invite, keys)
    private val deadlineNanos = System.nanoTime() + Pairing.LIFETIME_MILLIS * 1_000_000L
    @Volatile private var activeSocket: Socket? = null

    fun receive(): SourceConfig? {
        var attempts = 0
        var lastAttempt = 0L
        try {
            while (!closed.get() && !session.completed && System.nanoTime() < deadlineNanos) {
                val socket = try { server.accept() } catch (_: SocketTimeoutException) { continue }
                activeSocket = socket
                socket.use { client ->
                    client.soTimeout = 3000
                    val now = System.nanoTime()
                    if (!Pairing.isPrivateIpv4(client.inetAddress.hostAddress.orEmpty()) || ++attempts > 30 || now - lastAttempt < 250_000_000L) {
                        runCatching { reply(client, 429, "Too Many Requests") }
                        return@use
                    }
                    lastAttempt = now
                    val source = runCatching {
                        val body = readBody(client)
                        require(System.nanoTime() < deadlineNanos && !closed.get())
                        session.accept(body)
                    }.getOrNull()
                    if (source == null) {
                        runCatching { reply(client, 400, "Bad Request") }
                    } else if (!closed.get()) {
                        runCatching { reply(client, 204, "No Content") }
                        return source
                    }
                }
                activeSocket = null
                if (attempts >= 30) return null
            }
            return null
        } catch (_: IOException) {
            return null
        } finally {
            close()
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            runCatching { activeSocket?.close() }
            runCatching { server.close() }
        }
    }

    private fun readBody(socket: Socket): ByteArray {
        val input = BufferedInputStream(socket.getInputStream())
        val readDeadline = minOf(deadlineNanos, System.nanoTime() + 3_000_000_000L)
        var headerBytes = 0
        fun line(): String {
            val bytes = ArrayList<Byte>()
            while (true) {
                val next = input.read()
                require(next != -1 && ++headerBytes <= 4096 && bytes.size < 1024 && System.nanoTime() < readDeadline && !closed.get())
                if (next == 10) {
                    require(bytes.lastOrNull() == 13.toByte())
                    return bytes.dropLast(1).toByteArray().toString(Charsets.US_ASCII)
                }
                require(next in 32..126 || next == 13)
                bytes.add(next.toByte())
            }
        }
        val requestLine = line()
        require(requestLine == "POST /pair HTTP/1.1" || requestLine == "POST /pair HTTP/1.0")
        val headers = mutableMapOf<String, String>()
        while (true) {
            val header = line()
            if (header.isEmpty()) break
            val separator = header.indexOf(':')
            require(separator > 0)
            val name = header.substring(0, separator).lowercase()
            require(name !in headers)
            headers[name] = header.substring(separator + 1).trim()
        }
        require("transfer-encoding" !in headers && "origin" !in headers)
        require(headers["content-type"]?.substringBefore(';')?.trim() == "application/json")
        val length = headers["content-length"]?.toIntOrNull() ?: throw IOException("Invalid request")
        require(length in 1..Pairing.MAX_BODY_BYTES)
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            require(System.nanoTime() < readDeadline && !closed.get())
            val count = input.read(body, read, length - read)
            require(count > 0)
            read += count
        }
        require(System.nanoTime() < readDeadline && !closed.get())
        return body
    }

    private fun reply(socket: Socket, code: Int, label: String) {
        socket.getOutputStream().apply {
            write("HTTP/1.1 $code $label\r\nContent-Length: 0\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".toByteArray(Charsets.US_ASCII))
            flush()
        }
    }

    companion object {
        fun open(): PairingReceiver {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
                .filter { it.isUp && !it.isLoopback }
                .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
            val address = interfaces.flatMap { Collections.list(it.inetAddresses) }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { Pairing.isPrivateIpv4(it.hostAddress.orEmpty()) }
                ?: throw IOException("Connect the TV to your home Wi-Fi or Ethernet network.")
            val keys = Pairing.createKeys()
            val server = ServerSocket().apply {
                reuseAddress = false
                bind(java.net.InetSocketAddress(InetAddress.getByAddress(address.address), 0), 2)
                soTimeout = 1000
            }
            return try {
                PairingReceiver(Pairing.createInvite(address.hostAddress.orEmpty(), server.localPort, keys), keys, server)
            } catch (error: Exception) {
                server.close()
                throw error
            }
        }
    }
}

internal suspend fun sendPairing(invite: PairingInvite, source: SourceConfig) {
    val body = Pairing.encrypt(invite, source)
    val client = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .connectTimeout(3, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(8, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(8, java.util.concurrent.TimeUnit.SECONDS)
        .callTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .build()
    val request = Request.Builder().url("http://${invite.host}:${invite.port}/pair")
        .post(body.toRequestBody("application/json".toMediaType()))
        .header("Cache-Control", "no-store")
        .build()
    suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(IOException("The TV could not be reached. Check Wi-Fi and scan a new TV code."))
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    if (continuation.isActive) {
                        if (it.code == 204) continuation.resume(Unit)
                        else continuation.resumeWithException(IOException("Pairing was not accepted. Open a new code on the TV and try again."))
                    }
                }
            }
        })
    }
}
