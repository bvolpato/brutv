package com.bvolpato.brutv.signin

import android.content.Context
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bvolpato.brutv.data.LibraryState
import com.bvolpato.brutv.data.ProfileStore
import com.bvolpato.brutv.data.ProfileStoreException
import com.bvolpato.brutv.data.SavedState
import com.bvolpato.brutv.data.SourceConfig
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidIntegrationTest {
    @Test
    fun androidKeystoreRoundTripAndTamperLeaveTheEncryptedFileIntact() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext
        val folder = File(app.cacheDir, "profile-test-${UUID.randomUUID()}").apply { mkdirs() }
        val context = object : ContextWrapper(app) {
            override fun getApplicationContext(): Context = this
            override fun getNoBackupFilesDir(): File = folder
        }
        try {
            val source = SourceConfig(name = "Test source", server = "https://provider.example", username = "qa-user", password = "qa-secret-value")
            val expected = SavedState(
                profiles = listOf(source),
                activeSourceId = source.id,
                libraries = mapOf(source.id to LibraryState(favoriteIds = setOf("live-1"), resumePositions = mapOf("movie-2" to 4500L))),
            )
            ProfileStore(context).write(expected)
            assertEquals(expected, ProfileStore(context).read())
            val encrypted = folder.listFiles()!!.single { it.name.endsWith(".enc") }
            val bytes = encrypted.readBytes()
            assertFalse(bytes.toString(Charsets.UTF_8).contains(source.password))
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
            encrypted.writeBytes(bytes)
            try {
                ProfileStore(context).read()
                fail("A modified authenticated ciphertext must be rejected")
            } catch (_: ProfileStoreException) {
                assertTrue(encrypted.readBytes().contentEquals(bytes))
            }
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test
    fun encryptedPairingTraversesTheActualAndroidSocketAndCryptoProviders() = runBlocking {
        val receiver = PairingReceiver.open()
        val source = SourceConfig(name = "Living room", server = "https://provider.example", username = "a+b", password = "p&=?#")
        try {
            withTimeout(15_000) {
                val received = async(Dispatchers.IO) { receiver.receive() }
                sendPairing(receiver.invite, source)
                val actual = received.await() ?: error("Pairing returned no source")
                assertEquals(source.name, actual.name)
                assertEquals(source.server, actual.server)
                assertEquals(source.username, actual.username)
                assertEquals(source.password, actual.password)
            }
        } finally {
            receiver.close()
        }
    }
}
