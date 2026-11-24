package com.bvolpato.brutv.data

import com.google.gson.GsonBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileStoreNormalizationTest {
    @Test
    fun normalizesLegacySparseGsonDecodedSavedStateWithoutNullPointerExceptions() {
        val gson = GsonBuilder().disableHtmlEscaping().create()
        val legacyJson = """
            {
              "profiles": [
                {
                  "id": null,
                  "name": null,
                  "type": null,
                  "server": "https://provider.example",
                  "username": "viewer",
                  "password": "secret"
                },
                null
              ],
              "activeSourceId": "missing",
              "libraries": {
                "profile-1": {
                  "favoriteIds": ["live-1", null],
                  "recentIds": null,
                  "resumePositions": {"movie-1": 4200, "movie-neg": -100, "movie-null": null}
                },
                "null-lib": null
              },
              "bufferProfile": "",
              "showStats": true
            }
        """.trimIndent()

        val raw = gson.fromJson(legacyJson, SavedState::class.java)
        val normalized = normalizeDecodedSavedState(raw)

        assertEquals("system", normalized.language)
        assertEquals("balanced", normalized.bufferProfile)
        assertTrue(normalized.showStats)
        assertEquals(1, normalized.profiles.size)
        val profile = normalized.profiles.single()
        assertTrue(profile.id.isNotBlank())
        assertEquals("", profile.name)
        assertEquals(SourceType.XTREAM, profile.type)
        assertEquals("", profile.playlistUrl)

        assertEquals(setOf("profile-1"), normalized.libraries.keys)
        val library = normalized.libraries["profile-1"]
        assertNotNull(library)
        assertEquals(setOf("live-1"), library!!.favoriteIds)
        assertEquals(emptyList<String>(), library.recentIds)
        assertEquals(mapOf("movie-1" to 4200L, "movie-neg" to 0L), library.resumePositions)
        assertEquals(false, normalized.liveRewind)
        assertEquals(null, normalized.preferredAudioLanguage)
        assertEquals(null, normalized.preferredSubtitleLanguage)
        assertEquals(false, normalized.subtitlesEnabled)
        assertEquals("fit", normalized.defaultAspectMode)
        assertEquals(false, normalized.autoFrameRate)
    }

    @Test
    fun updateResumePositionsClearsAt95PercentOrCompletionAndCapsLruAt500() {
        var map = emptyMap<String, Long>()
        map = updateResumePositions(map, "movie-1", positionMs = 30_000L, durationMs = 100_000L)
        assertEquals(30_000L, map["movie-1"])

        // Reaching >= 95% clears resume position.
        map = updateResumePositions(map, "movie-1", positionMs = 95_000L, durationMs = 100_000L)
        assertTrue("movie-1" !in map)

        // Explicit STATE_ENDED completion clears resume position even without duration.
        map = updateResumePositions(map, "ep-1", positionMs = 45_000L, durationMs = 0L)
        assertEquals(45_000L, map["ep-1"])
        map = updateResumePositions(map, "ep-1", positionMs = 45_000L, durationMs = 0L, completed = true)
        assertTrue("ep-1" !in map)

        // LRU cap evicts eldest entries beyond 500 while preserving recently updated entries.
        var lru = emptyMap<String, Long>()
        for (i in 1..520) {
            lru = updateResumePositions(lru, "item-$i", positionMs = i * 1_000L, durationMs = 1_000_000L)
        }
        assertEquals(MAX_RESUME_POSITIONS, lru.size)
        assertTrue("item-1" !in lru)
        assertTrue("item-20" !in lru)
        assertEquals(21_000L, lru["item-21"])
        assertEquals(520_000L, lru["item-520"])

        // Touching item-21 refreshes its recency so item-22 is evicted next.
        lru = updateResumePositions(lru, "item-21", positionMs = 99_000L, durationMs = 1_000_000L)
        lru = updateResumePositions(lru, "item-521", positionMs = 1_000L, durationMs = 1_000_000L)
        assertEquals(MAX_RESUME_POSITIONS, lru.size)
        assertEquals(99_000L, lru["item-21"])
        assertTrue("item-22" !in lru)
    }

    @Test
    fun normalizesPersistedPlaybackPreferences() {
        val gson = GsonBuilder().disableHtmlEscaping().create()
        val json = """
            {
              "profiles": [],
              "libraries": {},
              "bufferProfile": "ultra_low",
              "showStats": false,
              "language": "pt",
              "liveRewind": true,
              "preferredAudioLanguage": "pt",
              "preferredSubtitleLanguage": "en",
              "subtitlesEnabled": true,
              "defaultAspectMode": "zoom",
              "autoFrameRate": true
            }
        """.trimIndent()
        val normalized = normalizeDecodedSavedState(gson.fromJson(json, SavedState::class.java))
        assertEquals("pt", normalized.language)
        assertTrue(normalized.liveRewind)
        assertEquals("pt", normalized.preferredAudioLanguage)
        assertEquals("en", normalized.preferredSubtitleLanguage)
        assertTrue(normalized.subtitlesEnabled)
        assertEquals("zoom", normalized.defaultAspectMode)
        assertTrue(normalized.autoFrameRate)
    }
}
