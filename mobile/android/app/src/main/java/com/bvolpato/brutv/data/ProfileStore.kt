package com.bvolpato.brutv.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.JsonParser
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.security.InvalidKeyException
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class ProfileStoreException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * Non-sensitive local watch history and playback preferences stored separately from encrypted
 * provider credentials so routine progress/settings updates never re-encrypt or fsync credentials.
 */
internal data class PreferencesState(
    val libraries: Map<String, LibraryState> = emptyMap(),
    val bufferProfile: String = "balanced",
    val showStats: Boolean = false,
    val language: String = "system",
    val liveRewind: Boolean = false,
    val preferredAudioLanguage: String? = null,
    val preferredSubtitleLanguage: String? = null,
    val subtitlesEnabled: Boolean = false,
    val defaultAspectMode: String = "fit",
    val autoFrameRate: Boolean = false,
)

/**
 * Encrypted profile storage (`brutv_profiles.enc`) plus separate unencrypted preferences/history
 * storage (`brutv_prefs.json`) in Android's no-backup app directory. Call from an IO dispatcher.
 */
class ProfileStore(context: Context) {
    private val appContext = context.applicationContext
    private val credentialsFile = AtomicFile(File(appContext.noBackupFilesDir, FILE_NAME))
    private val preferencesFile = AtomicFile(File(appContext.noBackupFilesDir, PREFS_FILE_NAME))
    private val gson: Gson = GsonBuilder().disableHtmlEscaping().create()
    @Volatile private var cachedKey: SecretKey? = null

    @Synchronized
    fun read(): SavedState {
        val hasCredentials = credentialsFile.baseFile.exists() || File(credentialsFile.baseFile.path + ".bak").exists()
        val encryptedState = if (hasCredentials) readCredentialsFile() else SavedState()
        val prefs = readPreferencesFileOrNull()
        return if (prefs != null) {
            normalizeDecodedSavedState(
                encryptedState.copy(
                    libraries = prefs.libraries,
                    bufferProfile = prefs.bufferProfile,
                    showStats = prefs.showStats,
                    language = prefs.language,
                    liveRewind = prefs.liveRewind,
                    preferredAudioLanguage = prefs.preferredAudioLanguage,
                    preferredSubtitleLanguage = prefs.preferredSubtitleLanguage,
                    subtitlesEnabled = prefs.subtitlesEnabled,
                    defaultAspectMode = prefs.defaultAspectMode,
                    autoFrameRate = prefs.autoFrameRate,
                ),
            )
        } else {
            encryptedState
        }
    }

    @Synchronized
    fun write(state: SavedState) {
        writeCredentials(state)
        writePreferences(state)
    }

    /** Encrypts and persists provider profiles + activeSourceId only. */
    @Synchronized
    fun writeCredentials(state: SavedState) {
        var plain: ByteArray? = null
        var encrypted: ByteArray? = null
        var output: java.io.FileOutputStream? = null
        try {
            val credentialsOnly = SavedState(
                profiles = state.profiles,
                activeSourceId = state.activeSourceId,
                libraries = emptyMap(),
                bufferProfile = state.bufferProfile,
                showStats = state.showStats,
                language = state.language,
                liveRewind = state.liveRewind,
                preferredAudioLanguage = state.preferredAudioLanguage,
                preferredSubtitleLanguage = state.preferredSubtitleLanguage,
                subtitlesEnabled = state.subtitlesEnabled,
                defaultAspectMode = state.defaultAspectMode,
                autoFrameRate = state.autoFrameRate,
            )
            val serialized = gson.toJson(credentialsOnly).toByteArray(Charsets.UTF_8)
            plain = serialized
            if (serialized.size > MAX_PLAINTEXT_BYTES) {
                throw ProfileStoreException("Saved profiles exceed the supported size.")
            }
            val (iv, ciphertext) = encryptWithKeyRetry(serialized)
            val envelope = byteArrayOf(FORMAT_VERSION) + iv + ciphertext
            encrypted = envelope
            val stream = credentialsFile.startWrite()
            output = stream
            stream.write(envelope)
            credentialsFile.finishWrite(stream)
            output = null
        } catch (error: ProfileStoreException) {
            output?.let { credentialsFile.failWrite(it) }
            throw error
        } catch (error: Exception) {
            output?.let { credentialsFile.failWrite(it) }
            throw ProfileStoreException("Saved profiles could not be encrypted and saved.", error)
        } finally {
            plain?.fill(0)
            encrypted?.fill(0)
        }
    }

    /** Persists non-sensitive watch history, favorites, and playback preferences without keystore IPC. */
    @Synchronized
    fun writePreferences(state: SavedState) {
        var output: java.io.FileOutputStream? = null
        try {
            val prefs = PreferencesState(
                libraries = state.libraries,
                bufferProfile = state.bufferProfile,
                showStats = state.showStats,
                language = state.language,
                liveRewind = state.liveRewind,
                preferredAudioLanguage = state.preferredAudioLanguage,
                preferredSubtitleLanguage = state.preferredSubtitleLanguage,
                subtitlesEnabled = state.subtitlesEnabled,
                defaultAspectMode = state.defaultAspectMode,
                autoFrameRate = state.autoFrameRate,
            )
            val serialized = gson.toJson(prefs).toByteArray(Charsets.UTF_8)
            if (serialized.size > MAX_PLAINTEXT_BYTES) {
                throw ProfileStoreException("Saved preferences exceed the supported size.")
            }
            val stream = preferencesFile.startWrite()
            output = stream
            stream.write(serialized)
            preferencesFile.finishWrite(stream)
            output = null
        } catch (error: ProfileStoreException) {
            output?.let { preferencesFile.failWrite(it) }
            throw error
        } catch (error: Exception) {
            output?.let { preferencesFile.failWrite(it) }
            throw ProfileStoreException("Saved preferences could not be written.", error)
        }
    }

    private fun readCredentialsFile(): SavedState {
        var encrypted: ByteArray? = null
        return try {
            val payload = credentialsFile.openRead().use { input ->
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
            val iv = payload.copyOfRange(ivStart, ivEnd)
            val plain = decryptWithKeyRetry(iv, payload, ivEnd, payload.size - ivEnd)
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

    private fun readPreferencesFileOrNull(): PreferencesState? {
        if (!preferencesFile.baseFile.exists() && !File(preferencesFile.baseFile.path + ".bak").exists()) return null
        return runCatching {
            val payload = preferencesFile.openRead().use { input ->
                val output = ByteArrayOutputStream()
                val chunk = ByteArray(8_192)
                var total = 0
                while (true) {
                    val read = input.read(chunk)
                    if (read < 0) break
                    total += read
                    if (total > MAX_PLAINTEXT_BYTES) return null
                    output.write(chunk, 0, read)
                }
                output.toByteArray()
            }
            val json = JsonParser.parseString(String(payload, Charsets.UTF_8))
            if (!json.isJsonObject) return null
            gson.fromJson(json, PreferencesState::class.java)
        }.getOrNull()
    }

    private fun encryptWithKeyRetry(plaintext: ByteArray): Pair<ByteArray, ByteArray> {
        return try {
            doEncrypt(plaintext, encryptionKey(forceReload = false))
        } catch (error: Exception) {
            if (isKeyCacheInvalidation(error)) {
                cachedKey = null
                doEncrypt(plaintext, encryptionKey(forceReload = true))
            } else {
                throw error
            }
        }
    }

    private fun doEncrypt(plaintext: ByteArray, key: SecretKey): Pair<ByteArray, ByteArray> {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(AAD)
        return cipher.iv to cipher.doFinal(plaintext)
    }

    private fun decryptWithKeyRetry(iv: ByteArray, payload: ByteArray, offset: Int, length: Int): ByteArray {
        return try {
            doDecrypt(iv, payload, offset, length, encryptionKey(forceReload = false))
        } catch (error: Exception) {
            if (isKeyCacheInvalidation(error)) {
                cachedKey = null
                doDecrypt(iv, payload, offset, length, encryptionKey(forceReload = true))
            } else {
                throw error
            }
        }
    }

    private fun doDecrypt(iv: ByteArray, payload: ByteArray, offset: Int, length: Int, key: SecretKey): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        cipher.updateAAD(AAD)
        return cipher.doFinal(payload, offset, length)
    }

    private fun isKeyCacheInvalidation(error: Throwable): Boolean =
        error is InvalidKeyException ||
            error is KeyPermanentlyInvalidatedException ||
            error is UnrecoverableKeyException

    private fun encryptionKey(forceReload: Boolean): SecretKey {
        if (!forceReload) {
            cachedKey?.let { return it }
        }
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let {
            cachedKey = it
            return it
        }
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
        return generator.generateKey().also { cachedKey = it }
    }

    companion object {
        private const val FILE_NAME = "brutv_profiles.enc"
        private const val PREFS_FILE_NAME = "brutv_prefs.json"
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
        val safeResume = LinkedHashMap<String, Long>()
        rawResume?.entries.orEmpty().forEach { resumeEntry ->
            val entryId = resumeEntry.key as? String ?: return@forEach
            val position = (resumeEntry.value as? Number)?.toLong() ?: return@forEach
            safeResume[entryId] = position.coerceAtLeast(0L)
        }
        while (safeResume.size > MAX_RESUME_POSITIONS) {
            val eldest = safeResume.entries.iterator().next().key
            safeResume.remove(eldest)
        }
        key to LibraryState(
            favoriteIds = safeFavorites,
            recentIds = safeRecents,
            resumePositions = safeResume,
        )
    }.toMap()
    val safeAspect = (asNullable(raw.defaultAspectMode) as? String).orEmpty().let { mode ->
        if (mode in setOf("fit", "zoom", "fill")) mode else "fit"
    }
    return SavedState(
        profiles = safeProfiles,
        activeSourceId = raw.activeSourceId,
        libraries = safeLibraries,
        bufferProfile = (asNullable(raw.bufferProfile) as? String).orEmpty().ifBlank { "balanced" },
        showStats = raw.showStats,
        language = (asNullable(raw.language) as? String).orEmpty().ifBlank { "system" },
        liveRewind = raw.liveRewind,
        preferredAudioLanguage = (asNullable(raw.preferredAudioLanguage) as? String)?.trim()?.takeIf { it.isNotEmpty() },
        preferredSubtitleLanguage = (asNullable(raw.preferredSubtitleLanguage) as? String)?.trim()?.takeIf { it.isNotEmpty() },
        subtitlesEnabled = raw.subtitlesEnabled,
        defaultAspectMode = safeAspect,
        autoFrameRate = raw.autoFrameRate,
    )
}

private fun asNullable(value: Any?): Any? = value
