package com.bvolpato.brutv.signin

import com.bvolpato.brutv.data.LoginLinks
import com.bvolpato.brutv.data.SourceConfig
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean

class QrContentTest {
    @Test fun unsupportedCodesDoNotPreventAValidSubsequentCode() {
        val delivered = AtomicBoolean(false)
        assertNull(claimSupportedQr("A shopping receipt", delivered))
        assertNull(claimSupportedQr("brutv://login?server=https%3A%2F%2Fprovider.example&username=family", delivered))
        assertFalse(delivered.get())
        val playlist = "https://provider.example/channels.m3u"
        assertEquals(playlist, claimSupportedQr(playlist, delivered))
        assertTrue(delivered.get())
        assertNull(claimSupportedQr(playlist, delivered))
        val invite = Pairing.createInvite("192.168.1.20", 48123, Pairing.createKeys())
        assertNotNull(supportedQrContent(Pairing.encodeInvite(invite)))
        assertNull(supportedQrContent(Pairing.encodeInvite(invite.copy(expiresAtMillis = System.currentTimeMillis() - 1))))
    }

    @Test fun generatedCredentialQrCanBeDecodedAndValidatedWithoutLosingReservedCharacters() {
        val source = SourceConfig(name = "Family", server = "https://provider.example", username = "family + &", password = "private?=#&+ value")
        val link = LoginLinks.encode(source)
        val matrix = QRCodeWriter().encode(link, BarcodeFormat.QR_CODE, 640, 640)
        val pixels = IntArray(matrix.width * matrix.height) { index -> if (matrix[index % matrix.width, index / matrix.width]) 0xff000000.toInt() else 0xffffffff.toInt() }
        val reader = MultiFormatReader()
        val decoded = reader.decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(matrix.width, matrix.height, pixels)))).text
        assertEquals(link, supportedQrContent(decoded))
        val received = requireNotNull(LoginLinks.parse(decoded))
        assertEquals(source.username, received.username)
        assertEquals(source.password, received.password)
    }
}
