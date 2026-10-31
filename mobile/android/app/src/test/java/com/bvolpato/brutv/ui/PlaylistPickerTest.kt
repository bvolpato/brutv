package com.bvolpato.brutv.ui

import android.content.ActivityNotFoundException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaylistPickerTest {
    @Test
    fun usesDocumentPickerWhenAvailable() {
        var opened = false
        assertTrue(launchPlaylistPicker({ opened = true }, { error("Fallback should not open") }))
        assertTrue(opened)
    }

    @Test
    fun missingDocumentPickerFallsBackToContentPicker() {
        var fallbackOpened = false
        assertTrue(launchPlaylistPicker({ throw ActivityNotFoundException() }, { fallbackOpened = true }))
        assertTrue(fallbackOpened)
    }

    @Test
    fun restrictedDocumentPickerFallsBackToContentPicker() {
        var fallbackOpened = false
        assertTrue(launchPlaylistPicker({ throw SecurityException() }, { fallbackOpened = true }))
        assertTrue(fallbackOpened)
    }

    @Test
    fun missingOrRestrictedPickersReportUnavailableWithoutCrashing() {
        assertFalse(launchPlaylistPicker({ throw ActivityNotFoundException() }, { throw ActivityNotFoundException() }))
        assertFalse(launchPlaylistPicker({ throw SecurityException() }, { throw SecurityException() }))
    }
}
