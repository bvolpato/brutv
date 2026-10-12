package com.bvolpato.brutv.signin

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.util.Size
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Replay
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.bvolpato.brutv.data.LoginLinks
import com.bvolpato.brutv.data.SourceConfig
import com.bvolpato.brutv.data.SourceType
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeWriter
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@Composable
fun QrScannerScreen(onResult: (String) -> Unit, onCancel: () -> Unit) {
    PrivateScreen()
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val currentResult by rememberUpdatedState(onResult)
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var error by remember { mutableStateOf<String?>(null) }
    var scanHint by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableStateOf(0) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        granted = allowed
        if (allowed) attempt++
        if (!allowed) error = "Camera access was not granted. You can still enter your provider details manually."
    }
    val previewView = remember { PreviewView(context) }
    val delivered = remember { AtomicBoolean(false) }
    DisposableEffect(granted, owner, attempt) {
        val disposed = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        val main = ContextCompat.getMainExecutor(context)
        val preview = Preview.Builder().build().apply { surfaceProvider = previewView.surfaceProvider }
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setTargetResolution(Size(1280, 720))
            .build()
        var provider: ProcessCameraProvider? = null
        if (granted) {
            var lastScanNanos = 0L
            analysis.setAnalyzer(executor) { image ->
                try {
                    val now = System.nanoTime()
                    if (!disposed.get() && !delivered.get() && now - lastScanNanos >= 250_000_000L) {
                        lastScanNanos = now
                        val scanned = decodeQr(image)
                        if (scanned != null) {
                            val supported = claimSupportedQr(scanned, delivered)
                            if (supported == null) {
                                main.execute {
                                    if (!disposed.get() && !delivered.get()) scanHint = "This code is not a supported sign-in or has expired. Scan a BruTV sign-in code, a playlist URL, or a new TV pairing code."
                                }
                            } else {
                                main.execute {
                                    if (!disposed.get()) {
                                        if (supportedQrContent(supported) != null) {
                                            scanHint = null
                                            currentResult(supported)
                                        } else {
                                            delivered.set(false)
                                            scanHint = "This TV pairing code has expired. Create a new code on the TV and scan it again."
                                        }
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    image.close()
                }
            }
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener({
                if (!disposed.get()) {
                    try {
                        provider = future.get()
                        provider?.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                    } catch (_: Exception) {
                        error = "The camera could not be opened. Use manual sign-in or try again."
                    }
                }
            }, main)
        }
        onDispose {
            disposed.set(true)
            analysis.clearAnalyzer()
            provider?.unbind(preview, analysis)
            executor.shutdownNow()
        }
    }
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Scan sign-in QR", style = MaterialTheme.typography.headlineMedium)
        Text("Scan a BruTV sign-in code or a TV pairing code. Keep account codes private.")
        scanHint?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (granted && error == null) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
            }
        } else {
            Text(error ?: "Camera access is used only while this scanner is open.")
            Button(onClick = {
                error = null
                if (granted) attempt++ else permission.launch(Manifest.permission.CAMERA)
            }) {
                Icon(if (granted) Icons.Outlined.Replay else Icons.Outlined.CameraAlt, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (granted) "Try again" else "Allow camera")
            }
        }
        TextButton(onClick = onCancel) {
            Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Cancel")
        }
    }
}

@Composable
fun LoginQrScreen(source: SourceConfig, onClose: () -> Unit) {
    PrivateScreen()
    val qr = remember(source) { runCatching { qrBitmap(LoginLinks.encode(source.normalized())) }.getOrNull() }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Share sign-in", style = MaterialTheme.typography.headlineMedium)
        Text("This code contains your provider credentials or private playlist address. Only show it to people you trust.")
        Text(source.name, style = MaterialTheme.typography.titleLarge)
        if (qr != null) QrImage(qr, "Private sign-in QR code")
        else if (source.type == SourceType.M3U && !source.playlistUrl.startsWith("http://", true) && !source.playlistUrl.startsWith("https://", true)) Text("An imported playlist file cannot be shared as a sign-in code. Import the file on the other device or use a playlist URL.")
        else Text("This profile is too large for a QR code. Use manual sign-in on the other device.")
        Text("Open BruTV’s QR scanner on another phone or tablet. An iPhone can also open this code with its camera.")
        Button(onClick = onClose) {
            Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Close")
        }
    }
}

@Composable
internal fun QrImage(bitmap: Bitmap, description: String) {
    Image(bitmap.asImageBitmap(), contentDescription = description, modifier = Modifier.fillMaxWidth().sizeIn(maxHeight = 420.dp).background(Color.White).padding(12.dp))
}

internal fun qrBitmap(value: String): Bitmap {
    val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 640, 640)
    val pixels = IntArray(640 * 640) { index -> if (matrix[index % 640, index / 640]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
    return Bitmap.createBitmap(pixels, 640, 640, Bitmap.Config.ARGB_8888)
}

private fun decodeQr(image: ImageProxy): String? = runCatching {
    val plane = image.planes[0]
    val buffer = plane.buffer
    val width = image.width
    val height = image.height
    val start = buffer.position()
    val data = ByteArray(width * height)
    for (y in 0 until height) {
        for (x in 0 until width) data[y * width + x] = buffer.get(start + y * plane.rowStride + x * plane.pixelStride)
    }
    val luminance = PlanarYUVLuminanceSource(data, width, height, 0, 0, width, height, false)
    val reader = MultiFormatReader().apply {
        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
    }
    try { reader.decodeWithState(BinaryBitmap(HybridBinarizer(luminance))).text.takeIf { it.length <= 8192 } }
    finally { reader.reset() }
}.getOrNull()

@Composable
internal fun PrivateScreen() {
    val context = LocalContext.current
    DisposableEffect(context) {
        val window = context.activity()?.window
        val alreadySecure = window?.attributes?.flags?.and(WindowManager.LayoutParams.FLAG_SECURE) != 0
        window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { if (!alreadySecure) window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
    }
}

private fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}
