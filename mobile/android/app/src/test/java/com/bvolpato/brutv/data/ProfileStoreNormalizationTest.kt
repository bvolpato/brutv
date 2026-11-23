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
    }
}
