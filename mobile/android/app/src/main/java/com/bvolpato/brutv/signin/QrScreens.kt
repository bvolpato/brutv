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
import androidx.compose.runtime.mutableIntStateOf
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
fun QrScannerScreen(onResult: (String) -> Unit, onCancel: () -> Unit, isPt: Boolean = false) {
    PrivateScreen()
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val currentResult by rememberUpdatedState(onResult)
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var error by remember { mutableStateOf<String?>(null) }
    var scanHint by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        granted = allowed
        if (allowed) attempt++
        if (!allowed) {
            error = if (isPt) {
                "O acesso à câmera não foi concedido. Você ainda pode inserir os detalhes do provedor manualmente."
            } else {
                "Camera access was not granted. You can still enter your provider details manually."
            }
        }
    }
    val previewView = remember { PreviewView(context) }
    val delivered = remember { AtomicBoolean(false) }
    DisposableEffect(granted, owner, attempt) {
        val disposed = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        val decoder = QrFrameDecoder()
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
                        val scanned = decoder.decode(image)
                        if (scanned != null) {
                            val supported = claimSupportedQr(scanned, delivered)
                            if (supported == null) {
                                main.execute {
                                    if (!disposed.get() && !delivered.get()) {
                                        scanHint = if (isPt) {
                                            "Este código não é um login válido ou expirou. Escaneie um código BruTV, uma URL de playlist ou um novo código da TV."
                                        } else {
                                            "This code is not a supported sign-in or has expired. Scan a BruTV sign-in code, a playlist URL, or a new TV pairing code."
                                        }
                                    }
                                }
                            } else {
                                main.execute {
                                    if (!disposed.get()) {
                                        if (supportedQrContent(supported) != null) {
                                            scanHint = null
                                            currentResult(supported)
                                        } else {
                                            delivered.set(false)
                                            scanHint = if (isPt) {
                                                "Este código de pareamento expirou. Crie um novo código na TV e escaneie novamente."
                                            } else {
                                                "This TV pairing code has expired. Create a new code on the TV and scan it again."
                                            }
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
                        error = if (isPt) {
                            "Não foi possível abrir a câmera. Use o login manual ou tente novamente."
                        } else {
                            "The camera could not be opened. Use manual sign-in or try again."
                        }
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
        Text(if (isPt) "Escanear QR de login" else "Scan sign-in QR", style = MaterialTheme.typography.headlineMedium)
        Text(if (isPt) "Escaneie um código de login do BruTV ou um código de pareamento da TV. Mantenha seus códigos privados." else "Scan a BruTV sign-in code or a TV pairing code. Keep account codes private.")
        scanHint?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (granted && error == null) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
            }
        } else {
            Text(error ?: if (isPt) "O acesso à câmera é usado apenas enquanto este leitor estiver aberto." else "Camera access is used only while this scanner is open.")
            Button(onClick = {
                error = null
                if (granted) attempt++ else permission.launch(Manifest.permission.CAMERA)
            }) {
                Icon(if (granted) Icons.Outlined.Replay else Icons.Outlined.CameraAlt, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (granted) (if (isPt) "Tentar novamente" else "Try again") else (if (isPt) "Permitir câmera" else "Allow camera"))
            }
        }
        TextButton(onClick = onCancel) {
            Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(if (isPt) "Cancelar" else "Cancel")
        }
    }
}

@Composable
fun LoginQrScreen(source: SourceConfig, onClose: () -> Unit, isPt: Boolean = false) {
    PrivateScreen()
    val qr = remember(source) { runCatching { qrBitmap(LoginLinks.encode(source.normalized())) }.getOrNull() }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(if (isPt) "Compartilhar login" else "Share sign-in", style = MaterialTheme.typography.headlineMedium)
        Text(if (isPt) "Este código contém suas credenciais do provedor ou endereço privado de playlist. Mostre apenas para pessoas de confiança." else "This code contains your provider credentials or private playlist address. Only show it to people you trust.")
        Text(source.name, style = MaterialTheme.typography.titleLarge)
        if (qr != null) QrImage(qr, if (isPt) "Código QR de login privado" else "Private sign-in QR code")
        else if (source.type == SourceType.M3U && !source.playlistUrl.startsWith("http://", true) && !source.playlistUrl.startsWith("https://", true)) {
            Text(if (isPt) "Um arquivo de playlist importado não pode ser compartilhado como QR. Importe o arquivo no outro dispositivo ou use uma URL." else "An imported playlist file cannot be shared as a sign-in code. Import the file on the other device or use a playlist URL.")
        } else {
            Text(if (isPt) "Este perfil é grande demais para um código QR. Use o login manual no outro dispositivo." else "This profile is too large for a QR code. Use manual sign-in on the other device.")
        }
        Text(if (isPt) "Abra o leitor QR do BruTV em outro celular ou tablet. Um iPhone também pode abrir este código pela câmera." else "Open BruTV’s QR scanner on another phone or tablet. An iPhone can also open this code with its camera.")
        Button(onClick = onClose) {
            Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(if (isPt) "Fechar" else "Close")
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

/**
 * Reuses YUV/rotation byte buffers and a single [MultiFormatReader] across camera frames
 * on the single-threaded analyzer executor to avoid per-frame multi-megabyte GC churn.
 */
private class QrFrameDecoder {
    private var yuvBuffer = ByteArray(0)
    private var rotatedBuffer = ByteArray(0)
    private val reader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
    }

    fun decode(image: ImageProxy): String? = runCatching {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val width = image.width
        val height = image.height
        val size = width * height
        if (yuvBuffer.size != size) {
            yuvBuffer = ByteArray(size)
        }
        val data = yuvBuffer
        val start = buffer.position()
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        if (pixelStride == 1 && rowStride == width) {
            buffer.get(data, 0, size)
            buffer.position(start)
        } else {
            for (y in 0 until height) {
                val rowOffset = start + y * rowStride
                val dstOffset = y * width
                for (x in 0 until width) {
                    data[dstOffset + x] = buffer.get(rowOffset + x * pixelStride)
                }
            }
        }
        val rotation = image.imageInfo.rotationDegrees
        val targetData: ByteArray
        val finalWidth: Int
        val finalHeight: Int
        when (rotation) {
            90 -> {
                if (rotatedBuffer.size != size) rotatedBuffer = ByteArray(size)
                val rotated = rotatedBuffer
                for (y in 0 until height) {
                    val row = y * width
                    val col = height - y - 1
                    for (x in 0 until width) {
                        rotated[x * height + col] = data[row + x]
                    }
                }
                targetData = rotated
                finalWidth = height
                finalHeight = width
            }
            180 -> {
                if (rotatedBuffer.size != size) rotatedBuffer = ByteArray(size)
                val rotated = rotatedBuffer
                for (i in 0 until size) {
                    rotated[size - 1 - i] = data[i]
                }
                targetData = rotated
                finalWidth = width
                finalHeight = height
            }
            270 -> {
                if (rotatedBuffer.size != size) rotatedBuffer = ByteArray(size)
                val rotated = rotatedBuffer
                for (y in 0 until height) {
                    val row = y * width
                    for (x in 0 until width) {
                        rotated[(width - x - 1) * height + y] = data[row + x]
                    }
                }
                targetData = rotated
                finalWidth = height
                finalHeight = width
            }
            else -> {
                targetData = data
                finalWidth = width
                finalHeight = height
            }
        }
        val luminance = PlanarYUVLuminanceSource(targetData, finalWidth, finalHeight, 0, 0, finalWidth, finalHeight, false)
        try {
            val result = runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(luminance))).text }.getOrNull()
                ?: runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(luminance.invert()))).text }.getOrNull()
            result?.takeIf { it.length <= 8192 }
        } finally {
            reader.reset()
        }
    }.getOrNull()
}

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
