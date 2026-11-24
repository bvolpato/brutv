package com.bvolpato.brutv.data

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale

data class CachedCatalogSection(
    val section: CatalogSection,
    val savedAtMs: Long,
    val isStale: Boolean,
)

/**
 * Compact binary on-disk cache for catalog sections (categories + up to 100k+ entries).
 * Uses atomic temp-file writes and omits Xtream credentials from disk by reconstructing
 * Xtream stream URLs dynamically on read.
 */
internal class CatalogDiskCache(
    private val directory: File,
    private val ttlMs: Long = DEFAULT_TTL_MS,
) {
    fun read(
        sourceId: String,
        kind: MediaKind,
        isXtream: Boolean,
        nowMs: Long = System.currentTimeMillis(),
        resolveXtreamUrl: (MediaKind, String, String) -> String = { _, _, _ -> "" },
    ): CachedCatalogSection? {
        val target = cacheFile(sourceId, kind)
        if (!target.isFile) return null
        return runCatching {
            DataInputStream(BufferedInputStream(FileInputStream(target), IO_BUFFER_BYTES)).use { input ->
                if (input.readInt() != MAGIC) return null
                if (input.readInt() != FORMAT_VERSION) return null
                val savedAtMs = input.readLong()
                val categoryCount = input.readInt()
                if (categoryCount < 0 || categoryCount > MAX_CATEGORIES) return null
                val categories = ArrayList<Category>(categoryCount)
                repeat(categoryCount) {
                    categories.add(Category(id = input.readString(), name = input.readString()))
                }
                val entryCount = input.readInt()
                if (entryCount < 0 || entryCount > MAX_ENTRIES) return null
                val entries = ArrayList<MediaEntry>(entryCount)
                repeat(entryCount) {
                    val id = input.readString()
                    val providerId = input.readString()
                    val name = input.readString()
                    val categoryId = input.readString()
                    val artwork = input.readString()
                    val rating = input.readString()
                    val plot = input.readString()
                    val containerExtension = input.readString()
                    val epgId = input.readString()
                    val storedUrl = input.readString()
                    val headerCount = input.readInt()
                    if (headerCount < 0 || headerCount > MAX_HEADERS_PER_ENTRY) return null
                    val headers = if (headerCount == 0) {
                        emptyMap()
                    } else {
                        val map = LinkedHashMap<String, String>(headerCount)
                        repeat(headerCount) {
                            map[input.readString()] = input.readString()
                        }
                        map
                    }
                    val streamUrl = if (isXtream && storedUrl.isEmpty()) {
                        resolveXtreamUrl(kind, providerId, containerExtension)
                    } else {
                        storedUrl
                    }
                    entries.add(
                        MediaEntry(
                            id = id,
                            providerId = providerId,
                            name = name,
                            kind = kind,
                            categoryId = categoryId,
                            artwork = artwork,
                            rating = rating,
                            plot = plot,
                            streamUrl = streamUrl,
                            containerExtension = containerExtension,
                            epgId = epgId,
                            requestHeaders = headers,
                        ),
                    )
                }
                val ageMs = nowMs - savedAtMs
                val isStale = ageMs < 0L || ageMs >= ttlMs
                CachedCatalogSection(
                    section = CatalogSection.build(categories, entries),
                    savedAtMs = savedAtMs,
                    isStale = isStale,
                )
            }
        }.getOrNull()
    }

    fun write(
        sourceId: String,
        kind: MediaKind,
        section: CatalogSection,
        isXtream: Boolean,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        runCatching {
            if (!directory.exists()) directory.mkdirs()
            if (!directory.isDirectory) return
            val target = cacheFile(sourceId, kind)
            val temp = File(directory, "${target.name}.${System.nanoTime()}.tmp")
            try {
                DataOutputStream(BufferedOutputStream(FileOutputStream(temp), IO_BUFFER_BYTES)).use { output ->
                    output.writeInt(MAGIC)
                    output.writeInt(FORMAT_VERSION)
                    output.writeLong(nowMs)
                    output.writeInt(section.categories.size)
                    for (category in section.categories) {
                        output.writeString(category.id)
                        output.writeString(category.name)
                    }
                    output.writeInt(section.entries.size)
                    for (entry in section.entries) {
                        output.writeString(entry.id)
                        output.writeString(entry.providerId)
                        output.writeString(entry.name)
                        output.writeString(entry.categoryId)
                        output.writeString(entry.artwork)
                        output.writeString(entry.rating)
                        output.writeString(entry.plot)
                        output.writeString(entry.containerExtension)
                        output.writeString(entry.epgId)
                        // Never write Xtream credentials into the unencrypted cache directory.
                        output.writeString(if (isXtream) "" else entry.streamUrl)
                        output.writeInt(entry.requestHeaders.size)
                        for ((k, v) in entry.requestHeaders) {
                            output.writeString(k)
                            output.writeString(v)
                        }
                    }
                    output.flush()
                }
                if (!temp.renameTo(target)) {
                    target.delete()
                    if (!temp.renameTo(target)) temp.delete()
                }
            } catch (_: Exception) {
                temp.delete()
            }
        }
    }

    fun clearSource(sourceId: String) {
        val prefix = "${safeFileKey(sourceId)}_"
        directory.listFiles()?.forEach { file ->
            if (file.isFile && file.name.startsWith(prefix)) {
                file.delete()
            }
        }
    }

    fun clearKind(sourceId: String, kind: MediaKind) {
        cacheFile(sourceId, kind).delete()
    }

    private fun cacheFile(sourceId: String, kind: MediaKind): File =
        File(directory, "${safeFileKey(sourceId)}_${kind.name.lowercase(Locale.ROOT)}.bin")

    private fun safeFileKey(sourceId: String): String {
        val sb = StringBuilder(sourceId.length)
        for (c in sourceId) {
            if (c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '-' || c == '_') sb.append(c)
            else sb.append('_')
        }
        return sb.toString().ifEmpty { "default" }
    }

    private fun DataOutputStream.writeString(value: String) {
        if (value.isEmpty()) {
            writeInt(0)
            return
        }
        val bytes = value.toByteArray(Charsets.UTF_8)
        writeInt(bytes.size)
        write(bytes)
    }

    private fun DataInputStream.readString(): String {
        val len = readInt()
        if (len == 0) return ""
        if (len < 0 || len > MAX_STRING_BYTES) throw IllegalStateException("Corrupted cache string length")
        val bytes = ByteArray(len)
        readFully(bytes)
        return String(bytes, Charsets.UTF_8)
    }

    companion object {
        const val DEFAULT_TTL_MS: Long = 6L * 60L * 60L * 1_000L
        private const val MAGIC = 0x42545643 // "BTVC"
        private const val FORMAT_VERSION = 1
        private const val IO_BUFFER_BYTES = 32 * 1024
        private const val MAX_CATEGORIES = 100_000
        private const val MAX_ENTRIES = 500_000
        private const val MAX_HEADERS_PER_ENTRY = 64
        private const val MAX_STRING_BYTES = 2 * 1024 * 1024
    }
}
