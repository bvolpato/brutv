package com.bvolpato.brutv.data

import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import java.util.zip.GZIPInputStream

/** Indexed XMLTV guide holding programmes within a bounded window around the current time. */
class XmltvGuide(
    private val byChannelId: Map<String, List<Programme>>,
    private val byDisplayName: Map<String, List<Programme>>,
    val fetchedAtMs: Long = System.currentTimeMillis(),
) {
    val isEmpty: Boolean get() = byChannelId.isEmpty() && byDisplayName.isEmpty()

    fun programmesFor(channel: MediaEntry): List<Programme> {
        val epgKey = normalizeKey(channel.epgId)
        if (epgKey.isNotEmpty()) {
            byChannelId[epgKey]?.let { return it }
        }
        val nameKey = normalizeKey(channel.name)
        if (nameKey.isNotEmpty()) {
            byDisplayName[nameKey]?.let { return it }
            byChannelId[nameKey]?.let { return it }
        }
        return emptyList()
    }

    fun nowAndNext(channel: MediaEntry, nowEpochSeconds: Long = System.currentTimeMillis() / 1_000L): Pair<Programme?, Programme?> {
        val list = programmesFor(channel)
        return findNowAndNext(list, nowEpochSeconds)
    }

    companion object {
        val EMPTY = XmltvGuide(emptyMap(), emptyMap(), 0L)

        fun normalizeKey(value: String): String =
            value.trim().lowercase(Locale.ROOT)

        fun findNowAndNext(
            programmes: List<Programme>,
            nowEpochSeconds: Long = System.currentTimeMillis() / 1_000L,
        ): Pair<Programme?, Programme?> {
            if (programmes.isEmpty()) return null to null
            var current: Programme? = null
            var next: Programme? = null
            for (programme in programmes) {
                if (programme.isLiveAt(nowEpochSeconds)) {
                    current = programme
                } else if (programme.startEpochSeconds >= nowEpochSeconds) {
                    if (next == null || programme.startEpochSeconds < next.startEpochSeconds) {
                        next = programme
                    }
                }
            }
            return current to next
        }
    }
}

/**
 * Streaming XMLTV parser backed by [XmlPullParser].
 * Discards programmes outside the requested `[windowStartEpochSeconds, windowEndEpochSeconds]` window
 * so large provider EPG dumps (10-50 MB) fit safely on low-RAM Android TV sticks.
 */
object XmltvParser {
    const val DEFAULT_MAX_BYTES: Long = 64L * 1024 * 1024
    const val DEFAULT_MAX_PROGRAMMES: Int = 200_000
    const val DEFAULT_PAST_WINDOW_SECONDS: Long = 2L * 3_600L
    const val DEFAULT_FUTURE_WINDOW_SECONDS: Long = 36L * 3_600L

    @Throws(IOException::class)
    fun parse(
        input: InputStream,
        nowEpochSeconds: Long = System.currentTimeMillis() / 1_000L,
        windowStartEpochSeconds: Long = nowEpochSeconds - DEFAULT_PAST_WINDOW_SECONDS,
        windowEndEpochSeconds: Long = nowEpochSeconds + DEFAULT_FUTURE_WINDOW_SECONDS,
        maxBytes: Long = DEFAULT_MAX_BYTES,
        maxProgrammes: Int = DEFAULT_MAX_PROGRAMMES,
        checkCancellation: () -> Unit = {},
        parserFactory: () -> XmlPullParser = { Xml.newPullParser() },
    ): XmltvGuide {
        val buffered = BufferedInputStream(XmltvBoundedInputStream(input, maxBytes), 16 * 1024)
        buffered.mark(2)
        val b0 = buffered.read()
        val b1 = buffered.read()
        buffered.reset()
        val stream: InputStream = if (b0 == 0x1F && b1 == 0x8B) {
            XmltvBoundedInputStream(GZIPInputStream(buffered, 16 * 1024), maxBytes * 4L)
        } else {
            buffered
        }

        val parser = parserFactory()
        try {
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        } catch (_: Exception) {
            // Optional on some implementations.
        }
        parser.setInput(stream, "UTF-8")

        val byChannelId = HashMap<String, ArrayList<Programme>>(256)
        val channelIdToNames = HashMap<String, ArrayList<String>>(256)
        var totalProgrammes = 0
        var eventCount = 0

        var inChannel = false
        var currentChannelId = ""

        var inProgramme = false
        var progChannel = ""
        var progStart = 0L
        var progStop = 0L
        var progTitle = ""
        var progDesc = ""
        var progInWindow = false

        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if ((++eventCount and 0xFF) == 0) checkCancellation()
            when (event) {
                XmlPullParser.START_TAG -> {
                    when (parser.name) {
                        "channel" -> {
                            inChannel = true
                            currentChannelId = XmltvGuide.normalizeKey(parser.getAttributeValue(null, "id").orEmpty())
                        }
                        "display-name" -> if (inChannel && currentChannelId.isNotEmpty()) {
                            val displayName = XmltvGuide.normalizeKey(readElementTextSafe(parser))
                            if (displayName.isNotEmpty()) {
                                val list = channelIdToNames[currentChannelId]
                                    ?: ArrayList<String>(2).also { channelIdToNames[currentChannelId] = it }
                                list.add(displayName)
                            }
                        }
                        "programme" -> {
                            inProgramme = true
                            progChannel = XmltvGuide.normalizeKey(parser.getAttributeValue(null, "channel").orEmpty())
                            progStart = parseXmltvTimestamp(parser.getAttributeValue(null, "start").orEmpty()) ?: 0L
                            progStop = parseXmltvTimestamp(parser.getAttributeValue(null, "stop").orEmpty()) ?: 0L
                            progTitle = ""
                            progDesc = ""
                            val effectiveEnd = if (progStop > progStart) progStop else progStart + 3_600L
                            progInWindow = progChannel.isNotEmpty() &&
                                progStart > 0L &&
                                effectiveEnd >= windowStartEpochSeconds &&
                                progStart <= windowEndEpochSeconds
                        }
                        "title" -> if (inProgramme && progInWindow && progTitle.isEmpty()) {
                            progTitle = readElementTextSafe(parser).trim()
                        }
                        "desc" -> if (inProgramme && progInWindow && progDesc.isEmpty()) {
                            progDesc = readElementTextSafe(parser).trim()
                        }
                    }
                }
                XmlPullParser.END_TAG -> {
                    when (parser.name) {
                        "channel" -> {
                            inChannel = false
                            currentChannelId = ""
                        }
                        "programme" -> {
                            if (inProgramme && progInWindow && progTitle.isNotEmpty() && totalProgrammes < maxProgrammes) {
                                val list = byChannelId[progChannel]
                                    ?: ArrayList<Programme>(8).also { byChannelId[progChannel] = it }
                                list.add(
                                    Programme(
                                        title = progTitle,
                                        description = progDesc,
                                        startEpochSeconds = progStart,
                                        endEpochSeconds = progStop,
                                    ),
                                )
                                totalProgrammes++
                            }
                            inProgramme = false
                            progInWindow = false
                        }
                    }
                }
            }
            event = parser.next()
        }

        val sortedById = HashMap<String, List<Programme>>(byChannelId.size)
        for ((channelId, list) in byChannelId) {
            list.sortBy { it.startEpochSeconds }
            sortedById[channelId] = list
        }
        val byDisplayName = HashMap<String, List<Programme>>(channelIdToNames.size)
        for ((channelId, names) in channelIdToNames) {
            val programmes = sortedById[channelId] ?: continue
            for (name in names) {
                if (!byDisplayName.containsKey(name)) {
                    byDisplayName[name] = programmes
                }
            }
        }
        return XmltvGuide(sortedById, byDisplayName)
    }

    private fun readElementTextSafe(parser: XmlPullParser): String {
        val sb = StringBuilder()
        var depth = 1
        while (depth > 0) {
            when (parser.next()) {
                XmlPullParser.TEXT, XmlPullParser.CDSECT -> sb.append(parser.text.orEmpty())
                XmlPullParser.START_TAG -> depth++
                XmlPullParser.END_TAG -> depth--
                XmlPullParser.END_DOCUMENT -> break
            }
        }
        return sb.toString()
    }

    /**
     * Parses XMLTV timestamp format (`YYYYMMDDHHMMSS [+-]HHMM` or `YYYYMMDDHHMMSS`) into UTC epoch seconds.
     */
    internal fun parseXmltvTimestamp(raw: String): Long? {
        val s = raw.trim()
        if (s.length < 14) return null
        val year = parseDigits(s, 0, 4) ?: return null
        val month = parseDigits(s, 4, 2) ?: return null
        val day = parseDigits(s, 6, 2) ?: return null
        val hour = parseDigits(s, 8, 2) ?: return null
        val minute = parseDigits(s, 10, 2) ?: return null
        val second = parseDigits(s, 12, 2) ?: return null
        if (month !in 1..12 || day !in 1..31 || hour !in 0..23 || minute !in 0..59 || second !in 0..60) return null

        var offsetSeconds = 0L
        var idx = 14
        while (idx < s.length && s[idx] == ' ') idx++
        if (idx < s.length) {
            val signChar = s[idx]
            if (signChar == '+' || signChar == '-') {
                if (idx + 5 <= s.length) {
                    val tzHour = parseDigits(s, idx + 1, 2) ?: return null
                    val tzMin = parseDigits(s, idx + 3, 2) ?: return null
                    val total = (tzHour * 3600L) + (tzMin * 60L)
                    offsetSeconds = if (signChar == '+') total else -total
                }
            }
        }

        val cal = Calendar.getInstance(UTC_TZ)
        cal.clear()
        cal.set(year, month - 1, day, hour, minute, second.coerceAtMost(59))
        return (cal.timeInMillis / 1_000L) - offsetSeconds
    }

    private fun parseDigits(s: String, start: Int, count: Int): Int? {
        if (start + count > s.length) return null
        var value = 0
        for (i in start until start + count) {
            val d = s[i] - '0'
            if (d !in 0..9) return null
            value = value * 10 + d
        }
        return value
    }

    private val UTC_TZ: TimeZone = TimeZone.getTimeZone("UTC")
}

private class XmltvBoundedInputStream(
    private val delegate: InputStream,
    private val limitBytes: Long,
) : InputStream() {
    private var bytesRead = 0L

    override fun read(): Int {
        val next = delegate.read()
        if (next >= 0 && ++bytesRead > limitBytes) {
            throw IOException("The EPG guide exceeds the size limit.")
        }
        return next
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val count = delegate.read(b, off, len)
        if (count > 0) {
            bytesRead += count
            if (bytesRead > limitBytes) {
                throw IOException("The EPG guide exceeds the size limit.")
            }
        }
        return count
    }

    override fun close() = delegate.close()
}
