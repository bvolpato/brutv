package com.bvolpato.brutv.signin

import com.bvolpato.brutv.data.SourceConfig
import com.bvolpato.brutv.data.SourceType
import com.google.gson.Gson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingTest {
    private val now = 1_000_000L
    private val invite get() = Pairing.createInvite("192.168.1.20", 48123, keys, now)
    private val source = SourceConfig(name = "Living room", server = "https://provider.example", username = "family-user", password = "private-password")

    @Test fun inviteRoundTripIsStrictlyLocalAndTimeBounded() {
        val original = invite
        val encoded = Pairing.encodeInvite(original)
        assertEquals(original, Pairing.parseInvite(encoded, now))
        assertNull(Pairing.parseInvite(encoded, original.expiresAtMillis))
        assertNull(Pairing.parseInvite(encoded, now - 31_000))
        assertNull(Pairing.parseInvite(encoded.replace("host=192.168.1.20", "host=example.com"), now))
        assertNull(Pairing.parseInvite(encoded.replace("host=192.168.1.20", "host=8.8.8.8"), now))
        assertNull(Pairing.parseInvite(encoded.replace("brutv://pair", "https://pair"), now))
        assertNull(Pairing.parseInvite(encoded.replace("brutv://pair", "brutv://user@pair"), now))
        assertNull(Pairing.parseInvite("$encoded&host=192.168.1.21", now))
        assertNull(Pairing.parseInvite("$encoded#fragment", now))
    }

    @Test fun encryptedProfilePreservesCredentialsAndLabelWithoutPlaintextTransmission() {
        val current = invite
        val body = Pairing.encrypt(current, source, now)
        val wire = body.toString(Charsets.UTF_8)
        assertFalse(wire.contains(source.username))
        assertFalse(wire.contains(source.password))
        assertFalse(wire.contains(source.server))
        val received = Pairing.decrypt(current, keys, body, now)
        assertEquals(source.name, received.name)
        assertEquals(source.username, received.username)
        assertEquals(source.password, received.password)
        assertEquals(source.server, received.server)
        assertEquals(source.type, received.type)
    }

    @Test fun tamperedCiphertextAndWrongTokensAreRejected() {
        val current = invite
        val envelope = Gson().fromJson(Pairing.encrypt(current, source, now).toString(Charsets.UTF_8), PairingEnvelope::class.java)
        val encrypted = Pairing.decodeBytes(envelope.ciphertext)
        encrypted[0] = (encrypted[0].toInt() xor 1).toByte()
        rejects { Pairing.decrypt(current, keys, json(envelope.copy(ciphertext = Pairing.encodeBytes(encrypted))), now) }
        rejects { Pairing.decrypt(current, keys, json(envelope.copy(token = invite.token)), now) }
        rejects { Pairing.decrypt(current, keys, json(envelope.copy(nonce = Pairing.encodeBytes(ByteArray(11)))), now) }
        rejects { Pairing.decrypt(current, keys, json(envelope.copy(version = 2)), now) }
        rejects { Pairing.decrypt(current, wrongKeys, json(envelope), now) }
    }

    @Test fun expiredAndOversizedMessagesAreRejected() {
        val current = invite
        val body = Pairing.encrypt(current, source, now)
        rejects { Pairing.decrypt(current, keys, body, current.expiresAtMillis) }
        rejects { Pairing.decrypt(current, keys, ByteArray(Pairing.MAX_BODY_BYTES + 1), now) }
        rejects { Pairing.encrypt(current, source, current.expiresAtMillis) }
    }

    @Test fun validProfilesAreAcceptedOnceAndInvalidTokensDoNotConsumeAnInvite() {
        val current = invite
        val session = PairingSession(current, keys)
        val body = Pairing.encrypt(current, source, now)
        val envelope = Gson().fromJson(body.toString(Charsets.UTF_8), PairingEnvelope::class.java)
        rejects { session.accept(json(envelope.copy(token = invite.token)), now) }
        assertFalse(session.completed)
        assertEquals(source.password, session.accept(body, now).password)
        assertTrue(session.completed)
        rejects { session.accept(body, now) }
    }

    @Test fun remotePlaylistsPairButDeviceLocalFilesDoNotLeaveTheirDevice() {
        val current = invite
        val playlist = SourceConfig(name = "Family channels", type = SourceType.M3U, playlistUrl = "https://provider.example/private.m3u?token=private")
        val received = Pairing.decrypt(current, keys, Pairing.encrypt(current, playlist, now), now)
        assertEquals(playlist.playlistUrl, received.playlistUrl)
        assertEquals(playlist.name, received.name)
        rejects { Pairing.encrypt(current, playlist.copy(playlistUrl = "file:///private/channels.m3u"), now) }
    }

    @Test fun privateIpv4ValidationRejectsAmbiguousOrRemoteHosts() {
        listOf("192.168.1.1", "10.0.0.2", "172.16.0.1", "172.31.255.254").forEach { assertTrue(Pairing.isPrivateIpv4(it)) }
        listOf("127.0.0.1", "0.0.0.0", "8.8.8.8", "172.32.0.1", "192.168.001.1", "192.168.1.256", "localhost", "192.168.1.1@evil.example", "::1").forEach { assertFalse(Pairing.isPrivateIpv4(it)) }
        assertFalse(Pairing.tokenMatches(invite.token, null))
        assertNotNull(Pairing.parseInvite(Pairing.encodeInvite(invite), now))
    }

    private fun json(envelope: PairingEnvelope) = Gson().toJson(envelope).toByteArray(Charsets.UTF_8)

    private fun rejects(action: () -> Unit) {
        val rejected = runCatching(action).isFailure
        assertTrue("The invalid pairing message should be rejected", rejected)
    }

    companion object {
        private val keys by lazy { Pairing.createKeys() }
        private val wrongKeys by lazy { Pairing.createKeys() }
    }
}
