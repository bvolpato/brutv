package com.bvolpato.brutv.ui

import android.content.ActivityNotFoundException

internal fun launchPlaylistPicker(openDocument: () -> Unit, getContent: () -> Unit): Boolean {
    for (launch in listOf(openDocument, getContent)) {
        try {
            launch()
            return true
        } catch (_: ActivityNotFoundException) {
            // Some Fire OS devices do not provide a document picker.
        } catch (_: SecurityException) {
            // A device policy can prevent access to an installed picker.
        }
    }
    return false
}
