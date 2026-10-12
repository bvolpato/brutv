package com.bvolpato.brutv.signin

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.bvolpato.brutv.data.SourceConfig
import com.bvolpato.brutv.data.SourceType
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun TvPairingScreen(onSource: (SourceConfig) -> Unit, onCancel: () -> Unit) {
    PrivateScreen()
    val currentSource by rememberUpdatedState(onSource)
    val owner = LocalLifecycleOwner.current
    val receiver = remember { AtomicReference<PairingReceiver?>(null) }
    val foreground = remember { AtomicBoolean(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    var invite by remember { mutableStateOf<PairingInvite?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableStateOf(0) }
    var seconds by remember { mutableStateOf(180) }
    val cancelFocus = remember { FocusRequester() }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) foreground.set(true)
            if (event == Lifecycle.Event.ON_STOP) {
                foreground.set(false)
                receiver.getAndSet(null)?.close()
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose {
            foreground.set(false)
            owner.lifecycle.removeObserver(observer)
            receiver.getAndSet(null)?.close()
        }
    }
    LaunchedEffect(attempt) {
        invite = null
        error = null
        var active: PairingReceiver? = null
        try {
            val opened = withContext(Dispatchers.IO) {
                PairingReceiver.open().also {
                    active = it
                    receiver.set(it)
                    if (!foreground.get()) it.close()
                }
            }
            active = opened
            ensureActive()
            invite = opened.invite
            val received = withContext(Dispatchers.IO) { opened.receive() }
            ensureActive()
            invite = null
            if (received != null) currentSource(received)
            else error = "This pairing code has expired or closed. Create a new code to try again."
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            invite = null
            error = "Pairing could not start. Connect the TV to your home Wi-Fi or Ethernet network and try again."
        } finally {
            active?.close()
            receiver.compareAndSet(active, null)
        }
    }
    LaunchedEffect(invite) {
        val current = invite ?: return@LaunchedEffect
        while (true) {
            seconds = ((current.expiresAtMillis - System.currentTimeMillis()).coerceAtLeast(0) / 1000).toInt()
            if (seconds == 0) {
                receiver.getAndSet(null)?.close()
                break
            }
            delay(1000)
        }
    }
    LaunchedEffect(Unit) { cancelFocus.requestFocus() }
    val bitmap = remember(invite) { invite?.let { runCatching { qrBitmap(Pairing.encodeInvite(it)) }.getOrNull() } }
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Sign in from your phone", style = MaterialTheme.typography.headlineMedium)
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            if (maxWidth >= 700.dp && bitmap != null) {
                Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        PairingInstructions(seconds)
                    }
                    Column(Modifier.weight(1f)) { QrImage(bitmap, "Temporary TV pairing QR code") }
                }
            } else {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (bitmap != null) {
                        PairingInstructions(seconds)
                        QrImage(bitmap, "Temporary TV pairing QR code")
                    } else if (error != null) {
                        Text(error.orEmpty())
                        Button(onClick = { attempt++ }) {
                            Icon(Icons.Outlined.QrCode2, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Create new code")
                        }
                    } else {
                        CircularProgressIndicator()
                        Text("Preparing a secure local connection…")
                    }
                }
            }
        }
        TextButton(onClick = {
            receiver.getAndSet(null)?.close()
            onCancel()
        }, modifier = Modifier.focusRequester(cancelFocus)) {
            Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Cancel")
        }
    }
}

@Composable
private fun PairingInstructions(seconds: Int) {
    Text("1. Connect your phone and TV to the same Wi-Fi network.")
    Text("2. Open BruTV on your Android phone, then open the QR scanner.")
    Text("3. Scan this code and choose the saved profile to send.")
    Text("The profile is encrypted directly to this TV. The code works once and expires in ${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}.")
    Text("This pairing feature needs BruTV on Android. For an iPhone, enter your provider details on the TV.", style = MaterialTheme.typography.bodySmall)
    Text("If pairing fails, turn off guest Wi-Fi isolation or use manual sign-in.", style = MaterialTheme.typography.bodySmall)
}

@Composable
fun PairingSendScreen(invite: PairingInvite, profiles: List<SourceConfig>, onDone: () -> Unit, onCancel: () -> Unit) {
    PrivateScreen()
    val scope = rememberCoroutineScope()
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val shareable = remember(profiles) {
        profiles.filter { it.type != SourceType.M3U || it.playlistUrl.startsWith("http://", true) || it.playlistUrl.startsWith("https://", true) }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Send a profile to your TV", style = MaterialTheme.typography.headlineMedium)
        Text("Both devices must be on the same Wi-Fi network. Check that the QR code is still visible on your TV, then choose a profile.")
        Text("Your provider credentials are encrypted for this TV. Send them only to a TV you trust.")
        if (error != null) Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
        if (shareable.isEmpty()) Text("Save a provider profile or a playlist URL on this phone first, then scan the TV code again.")
        if (shareable.size != profiles.size) Text("Imported playlist files are stored on this device. Import the file on the TV or use a playlist URL to share it.")
        shareable.forEach { source ->
            Button(onClick = {
                sending = true
                error = null
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) { sendPairing(invite, source) }
                        onDone()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        error = "The TV could not accept this profile. Keep both devices on the same Wi-Fi and scan a new TV code."
                    } finally {
                        sending = false
                    }
                }
            }, enabled = !sending, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.AutoMirrored.Outlined.Send, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(source.name)
            }
        }
        if (sending) {
            CircularProgressIndicator()
            Text("Sending securely…")
        }
        TextButton(onClick = onCancel) {
            Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Cancel")
        }
    }
}
