package com.bvolpato.brutv

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import com.bvolpato.brutv.ui.BruTvApp
import com.bvolpato.brutv.ui.BruTvViewModel

class MainActivity : ComponentActivity() {
    private lateinit var viewModel: BruTvViewModel
    private var activePlayer: Player? = null
    private var pictureInPicture by mutableStateOf(false)
    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) = updatePictureInPicture()
        override fun onVideoSizeChanged(videoSize: VideoSize) = updatePictureInPicture()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val isTv = getSystemService(UiModeManager::class.java).currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        if (isTv) {
            WindowInsetsControllerCompat(window, window.decorView).apply {
                hide(WindowInsetsCompat.Type.systemBars())
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
        viewModel = ViewModelProvider(this)[BruTvViewModel::class.java]
        if (savedInstanceState == null) intent?.dataString?.let(viewModel::acceptLink)
        setContent {
            BruTvApp(
                viewModel = viewModel,
                isTv = isTv,
                isInPictureInPictureMode = pictureInPicture,
                onPlayerChanged = ::bindPlayer,
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.let(viewModel::acceptLink)
    }

    private fun bindPlayer(player: Player?) {
        if (activePlayer === player) return
        activePlayer?.removeListener(playerListener)
        activePlayer = player
        player?.addListener(playerListener)
        updatePictureInPicture()
    }

    private fun updatePictureInPicture() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            !packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        val player = activePlayer
        val video = player?.videoSize
        val aspect = if (video != null && video.width > 0 && video.height > 0) {
            val ratio = (video.width.toFloat() * video.pixelWidthHeightRatio / video.height).coerceIn(0.42f, 2.39f)
            Rational((ratio * 1000).toInt(), 1000)
        } else Rational(16, 9)
        val params = PictureInPictureParams.Builder().setAspectRatio(aspect)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) params.setAutoEnterEnabled(player?.isPlaying == true)
        setPictureInPictureParams(params.build())
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activePlayer?.isPlaying == true &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            updatePictureInPicture()
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPicture = isInPictureInPictureMode
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val player = activePlayer
        if (player != null && event.action == KeyEvent.ACTION_DOWN) {
            when (keyCode) {
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> if (player.playWhenReady) player.pause() else playFromRemote(player)
                KeyEvent.KEYCODE_MEDIA_PLAY -> playFromRemote(player)
                KeyEvent.KEYCODE_MEDIA_PAUSE -> player.pause()
                KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> player.seekForward()
                KeyEvent.KEYCODE_MEDIA_REWIND -> player.seekBack()
                else -> return super.onKeyDown(keyCode, event)
            }
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun playFromRemote(player: Player) {
        if (player.playbackState == Player.STATE_IDLE) player.prepare()
        player.play()
    }

    override fun onDestroy() {
        activePlayer?.removeListener(playerListener)
        activePlayer = null
        super.onDestroy()
    }
}
