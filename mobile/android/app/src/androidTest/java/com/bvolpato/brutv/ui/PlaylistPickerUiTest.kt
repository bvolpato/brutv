package com.bvolpato.brutv.ui

import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.core.app.ActivityOptionsCompat
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.bvolpato.brutv.data.SourceType
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class PlaylistPickerUiTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun unavailablePickersKeepWelcomeOpenAndOfferPlaylistUrl() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val folder = File(context.cacheDir, "picker-test-${UUID.randomUUID()}").apply { mkdirs() }
        val application = object : Application() {
            override fun getApplicationContext(): Context = this
            override fun getNoBackupFilesDir(): File = folder
        }
        val viewModel = BruTvViewModel(application)
        val store = ViewModelStore().apply { put("picker", viewModel) }
        val attemptedActions = mutableListOf<String?>()
        val owner = object : ActivityResultRegistryOwner {
            override val activityResultRegistry = object : ActivityResultRegistry() {
                override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                    attemptedActions += contract.createIntent(context, input).action
                    throw ActivityNotFoundException()
                }
            }
        }
        try {
            compose.setContent {
                CompositionLocalProvider(LocalActivityResultRegistryOwner provides owner) {
                    BruTvApp(viewModel, isTv = true, onPlayerChanged = {})
                }
            }
            compose.waitUntil(10_000) { viewModel.state.value.initialized }
            compose.onNodeWithText("Import an M3U file").performScrollTo().performClick()
            compose.onNodeWithText("File picker unavailable").assertIsDisplayed()
            assertEquals(listOf(Intent.ACTION_OPEN_DOCUMENT, Intent.ACTION_GET_CONTENT), attemptedActions)
            compose.onNodeWithText("Add playlist URL").performClick()
            compose.runOnIdle {
                assertEquals(BruTvPage.SIGN_IN, viewModel.state.value.page)
                assertEquals(SourceType.M3U, viewModel.state.value.draft.type)
            }
            compose.onNodeWithText("M3U playlist URL").performScrollTo().assertIsDisplayed()
        } finally {
            store.clear()
            folder.deleteRecursively()
        }
    }
}
