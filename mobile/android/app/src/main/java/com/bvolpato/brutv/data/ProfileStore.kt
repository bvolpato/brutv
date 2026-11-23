package com.bvolpato.brutv.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.JsonParser
import java.io.File
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class ProfileStoreException(message: String, cause: Throwable? = null) : IOException(message, cause)

/** Encrypted profile storage in Android's no-backup app directory. Call from an IO dispatcher. */
class ProfileStore(context: Context) {
    private val appContext = context.applicationContext
    private val file = AtomicFile(File(appContext.noBackupFilesDir, FILE_NAME))
    private val gson: Gson = GsonBuilder().disableHtmlEscaping().create()

    @Synchronized
    fun read(): SavedState {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return SavedState()
        var encrypted: ByteArray? = null
        return try {
            val payload = file.openRead().use { input ->
                val output = ByteArrayOutputStream()
                val chunk = ByteArray(8_192)
                var total = 0
                while (true) {
                    val read = input.read(chunk)
                    if (read < 0) break
                    total += read
                    if (total > MAX_ENVELOPE_BYTES) {
                        throw ProfileStoreException("Saved profiles exceed the supported size. The encrypted file was left unchanged.")
                    }
                    output.write(chunk, 0, read)
                }
                output.toByteArray()
            }
            encrypted = payload
            if (payload.size !in MIN_ENVELOPE_BYTES..MAX_ENVELOPE_BYTES) {
                throw ProfileStoreException("Saved profiles are damaged. The encrypted file was left unchanged.")
            }
            if (payload[0] != FORMAT_VERSION) {
                throw ProfileStoreException("Saved profiles use an unsupported format. The encrypted file was left unchanged.")
            }
            val ivStart = 1
            val ivEnd = ivStart + GCM_IV_BYTES
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, encryptionKey(), GCMParameterSpec(GCM_TAG_BITS, payload.copyOfRange(ivStart, ivEnd)))
            cipher.updateAAD(AAD)
            val plain = cipher.doFinal(payload, ivEnd, payload.size - ivEnd)
            try {
                val json = JsonParser.parseString(String(plain, Charsets.UTF_8))
                if (!json.isJsonObject) throw ProfileStoreException("Saved profiles are damaged. The encrypted file was left unchanged.")
                val root = json.asJsonObject
                val bufferProfile = root.get("bufferProfile")
                val showStats = root.get("showStats")
                if (root.get("profiles")?.isJsonArray != true || root.get("libraries")?.isJsonObject != true ||
                    bufferProfile?.isJsonPrimitive != true || !bufferProfile.asJsonPrimitive.isString ||
                    showStats?.isJsonPrimitive != true || !showStats.asJsonPrimitive.isBoolean) {
                    throw ProfileStoreException("Saved profiles are damaged. The encrypted file was left unchanged.")
                }
                val decoded = gson.fromJson(json, SavedState::class.java)
                    ?: throw ProfileStoreException("Saved profiles are damaged. The encrypted file was left unchanged.")
                normalizeDecodedSavedState(decoded)
            } finally {
                plain.fill(0)
            }
        } catch (error: ProfileStoreException) {
            throw error
        } catch (error: Exception) {
            throw ProfileStoreException("Saved profiles could not be decrypted or read. The encrypted file was left unchanged.", error)
        } finally {
            encrypted?.fill(0)
        }
    }

    @Synchronized
    fun write(state: SavedState) {
        var plain: ByteArray? = null
        var encrypted: ByteArray? = null
        var output: java.io.FileOutputStream? = null
        try {
            val serialized = gson.toJson(state).toByteArray(Charsets.UTF_8)
            plain = serialized
            if (serialized.size > MAX_PLAINTEXT_BYTES) {
                throw ProfileStoreException("Saved profiles exceed the supported size.")
            }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
            cipher.updateAAD(AAD)
            val ciphertext = cipher.doFinal(serialized)
            val envelope = byteArrayOf(FORMAT_VERSION) + cipher.iv + ciphertext
            encrypted = envelope
            val stream = file.startWrite()
            output = stream
            stream.write(envelope)
            file.finishWrite(stream)
            output = null
        } catch (error: ProfileStoreException) {
            output?.let { file.failWrite(it) }
            throw error
        } catch (error: Exception) {
            output?.let { file.failWrite(it) }
            throw ProfileStoreException("Saved profiles could not be encrypted and saved.", error)
        } finally {
            plain?.fill(0)
            encrypted?.fill(0)
        }
    }

    private fun encryptionKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    companion object {
        private const val FILE_NAME = "brutv_profiles.enc"
        private const val KEY_ALIAS = "com.bvolpato.brutv.profile-store.v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT_VERSION: Byte = 1
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private const val MIN_ENVELOPE_BYTES = 1 + GCM_IV_BYTES + 16
        private const val MAX_PLAINTEXT_BYTES = 2 * 1024 * 1024
        private const val MAX_ENVELOPE_BYTES = MAX_PLAINTEXT_BYTES + MIN_ENVELOPE_BYTES
        private val AAD = "com.bvolpato.brutv.profile-store.v1".toByteArray(Charsets.UTF_8)
    }
}

/**
 * Gson deserializes via reflection and bypasses Kotlin non-null defaults when reading older schemas
 * or sparse JSON payloads. Normalize every potentially null field before returning state to callers.
 */
internal fun normalizeDecodedSavedState(raw: SavedState): SavedState {
    val rawProfiles = asNullable(raw.profiles) as? List<*>
    val safeProfiles = rawProfiles.orEmpty().mapNotNull { item ->
        val profile = item as? SourceConfig ?: return@mapNotNull null
        SourceConfig(
            id = (asNullable(profile.id) as? String).orEmpty().ifBlank { UUID.randomUUID().toString() },
            name = (asNullable(profile.name) as? String).orEmpty(),
            type = (asNullable(profile.type) as? SourceType) ?: SourceType.XTREAM,
            server = (asNullable(profile.server) as? String).orEmpty(),
            username = (asNullable(profile.username) as? String).orEmpty(),
            password = (asNullable(profile.password) as? String).orEmpty(),
            playlistUrl = (asNullable(profile.playlistUrl) as? String).orEmpty(),
        )
    }
    val rawLibraries = asNullable(raw.libraries) as? Map<*, *>
    val safeLibraries = rawLibraries?.entries.orEmpty().mapNotNull { entry ->
        val key = entry.key as? String ?: return@mapNotNull null
        val value = entry.value as? LibraryState ?: return@mapNotNull null
        val rawFavs = asNullable(value.favoriteIds) as? Iterable<*>
        val safeFavorites = rawFavs?.mapNotNull { it as? String }?.toSet().orEmpty()
        val rawRecents = asNullable(value.recentIds) as? Iterable<*>
        val safeRecents = rawRecents?.mapNotNull { it as? String }.orEmpty()
        val rawResume = asNullable(value.resumePositions) as? Map<*, *>
        val safeResume = rawResume?.entries.orEmpty().mapNotNull { resumeEntry ->
            val entryId = resumeEntry.key as? String ?: return@mapNotNull null
            val position = (resumeEntry.value as? Number)?.toLong() ?: return@mapNotNull null
            entryId to position.coerceAtLeast(0L)
        }.toMap()
        key to LibraryState(
            favoriteIds = safeFavorites,
            recentIds = safeRecents,
            resumePositions = safeResume,
        )
    }.toMap()
    return SavedState(
        profiles = safeProfiles,
        activeSourceId = raw.activeSourceId,
        libraries = safeLibraries,
        bufferProfile = (asNullable(raw.bufferProfile) as? String).orEmpty().ifBlank { "balanced" },
        showStats = raw.showStats,
        language = (asNullable(raw.language) as? String).orEmpty().ifBlank { "system" },
    )
}

private fun asNullable(value: Any?): Any? = value
