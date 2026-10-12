package com.bvolpato.brutv.signin

import com.bvolpato.brutv.data.LoginLinks
import com.bvolpato.brutv.data.SourceConfig
import com.google.gson.Gson
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.RSAPublicKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString

data class PairingInvite(
    val host: String,
    val port: Int,
    val token: String,
    val publicKey: String,
    val expiresAtMillis: Long,
) {
    override fun toString(): String = "PairingInvite(host=$host, port=$port, token=<redacted>, publicKey=<redacted>)"
}

internal data class PairingEnvelope(
    val version: Int,
    val token: String,
    val wrappedKey: String,
    val nonce: String,
    val ciphertext: String,
)

private data class PairingPayload(val name: String, val link: String)

internal class PairingSession(private val invite: PairingInvite, private val keys: KeyPair) {
    private val accepted = AtomicBoolean(false)
    val completed: Boolean get() = accepted.get()

    fun accept(body: ByteArray, nowMillis: Long = System.currentTimeMillis()): SourceConfig {
        check(!accepted.get())
        val source = Pairing.decrypt(invite, keys, body, nowMillis)
        check(accepted.compareAndSet(false, true))
        return source
    }
}

object Pairing {
    const val LIFETIME_MILLIS = 180_000L
    internal const val MAX_BODY_BYTES = 16_384
    private val random = SecureRandom()
    private val gson = Gson()
    private val oaep = OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)

    fun parseInvite(raw: String): PairingInvite? = parseInvite(raw, System.currentTimeMillis())

    internal fun parseInvite(raw: String, nowMillis: Long): PairingInvite? = runCatching {
        require(raw.length <= 4096)
        val uri = URI(raw)
        require(uri.scheme.equals("brutv", true) && uri.host.equals("pair", true))
        require(uri.rawUserInfo == null && uri.port == -1 && uri.rawFragment == null && uri.path.orEmpty().isEmpty())
        val pairs = uri.rawQuery.orEmpty().split('&').map { item ->
            val split = item.split('=', limit = 2)
            require(split.size == 2)
            URLDecoder.decode(split[0], "UTF-8") to URLDecoder.decode(split[1], "UTF-8")
        }
        require(pairs.map { it.first }.toSet().size == pairs.size)
        val fields = pairs.toMap()
        require(fields.keys == setOf("host", "port", "token", "key", "expires"))
        PairingInvite(
            host = fields.getValue("host"),
            port = fields.getValue("port").toInt(),
            token = fields.getValue("token"),
            publicKey = fields.getValue("key"),
            expiresAtMillis = fields.getValue("expires").toLong(),
        ).also { validate(it, nowMillis) }
    }.getOrNull()

    internal fun isPrivateIpv4(host: String): Boolean {
        if (!host.matches(Regex("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}"))) return false
        val parts = host.split('.').map { it.toIntOrNull() ?: return false }
        if (parts.any { it !in 0..255 } || parts.map(Int::toString).joinToString(".") != host) return false
        return parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) || (parts[0] == 192 && parts[1] == 168)
    }

    internal fun createKeys(): KeyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048, random) }.generateKeyPair()

    internal fun createInvite(host: String, port: Int, keys: KeyPair, nowMillis: Long = System.currentTimeMillis()): PairingInvite =
        PairingInvite(host, port, encodeBytes(ByteArray(32).also(random::nextBytes)), encodeBytes(keys.public.encoded), nowMillis + LIFETIME_MILLIS)
            .also { validate(it, nowMillis) }

    internal fun encodeInvite(invite: PairingInvite): String {
        val fields = linkedMapOf("host" to invite.host, "port" to invite.port.toString(), "token" to invite.token, "key" to invite.publicKey, "expires" to invite.expiresAtMillis.toString())
        return "brutv://pair?" + fields.entries.joinToString("&") { (key, value) -> "$key=${URLEncoder.encode(value, "UTF-8")}" }
    }

    internal fun encrypt(invite: PairingInvite, source: SourceConfig, nowMillis: Long = System.currentTimeMillis()): ByteArray {
        validate(invite, nowMillis)
        val normalized = source.normalized()
        require(normalized.name.length <= 255)
        val plain = gson.toJson(PairingPayload(normalized.name, LoginLinks.encode(normalized))).toByteArray(Charsets.UTF_8)
        require(plain.size in 1..8192) { "This profile is too large to transfer." }
        val key = KeyGenerator.getInstance("AES").apply { init(256, random) }.generateKey()
        val nonce = ByteArray(12).also(random::nextBytes)
        val aes = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
            updateAAD(aad(invite.token))
        }
        val encrypted = aes.doFinal(plain)
        val rsa = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding").apply { init(Cipher.ENCRYPT_MODE, readPublicKey(invite.publicKey), oaep) }
        val body = gson.toJson(PairingEnvelope(1, invite.token, encodeBytes(rsa.doFinal(key.encoded)), encodeBytes(nonce), encodeBytes(encrypted))).toByteArray(Charsets.UTF_8)
        require(body.size <= MAX_BODY_BYTES)
        return body
    }

    internal fun decrypt(invite: PairingInvite, keys: KeyPair, body: ByteArray, nowMillis: Long = System.currentTimeMillis()): SourceConfig {
        require(body.size in 1..MAX_BODY_BYTES)
        validate(invite, nowMillis)
        val envelope = gson.fromJson(body.toString(Charsets.UTF_8), PairingEnvelope::class.java)
        require(envelope.version == 1 && tokenMatches(invite.token, envelope.token))
        val wrappedKey = decodeBytes(envelope.wrappedKey)
        val nonce = decodeBytes(envelope.nonce)
        val ciphertext = decodeBytes(envelope.ciphertext)
        require(wrappedKey.size == 256 && nonce.size == 12 && ciphertext.size in 17..8208)
        val rsa = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding").apply { init(Cipher.DECRYPT_MODE, keys.private, oaep) }
        val key = rsa.doFinal(wrappedKey)
        require(key.size == 32)
        val aes = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(aad(invite.token))
        }
        val plain = aes.doFinal(ciphertext)
        val payload = gson.fromJson(plain.toString(Charsets.UTF_8), PairingPayload::class.java)
        require(payload.name.length in 1..255 && payload.link.length <= 8192)
        return requireNotNull(LoginLinks.parse(payload.link)).copy(name = payload.name).normalized()
    }

    internal fun tokenMatches(expected: String, received: String?): Boolean = received != null &&
        MessageDigest.isEqual(expected.toByteArray(Charsets.US_ASCII), received.toByteArray(Charsets.US_ASCII))

    private fun validate(invite: PairingInvite, nowMillis: Long) {
        require(isPrivateIpv4(invite.host) && invite.port in 1024..65535)
        require(invite.token.matches(Regex("[A-Za-z0-9_-]{43}")) && decodeBytes(invite.token).size == 32)
        require(invite.expiresAtMillis > nowMillis && invite.expiresAtMillis - nowMillis <= LIFETIME_MILLIS + 30_000L)
        readPublicKey(invite.publicKey)
    }

    private fun readPublicKey(encoded: String): RSAPublicKey {
        require(encoded.length in 300..600)
        return (KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(decodeBytes(encoded))) as RSAPublicKey).also {
            require(it.modulus.bitLength() == 2048 && it.publicExponent == java.math.BigInteger.valueOf(65537))
        }
    }

    private fun aad(token: String): ByteArray = "BruTV pairing v1:$token".toByteArray(Charsets.US_ASCII)
    internal fun encodeBytes(bytes: ByteArray): String = bytes.toByteString().base64Url().trimEnd('=')
    internal fun decodeBytes(value: String): ByteArray = requireNotNull(value.decodeBase64()).toByteArray()
}
