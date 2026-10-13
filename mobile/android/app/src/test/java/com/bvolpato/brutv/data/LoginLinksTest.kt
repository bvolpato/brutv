package com.bvolpato.brutv.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class LoginLinksTest {
    @Test
    fun xtreamLoginLinkRoundTripsReservedCharacters() {
        val profile = SourceConfig(
            name = "Family",
            server = "https://iptv.example:8443/panel/",
            username = "viewer+one&two",
            password = "secret /?#%",
        ).normalized()

        val encoded = LoginLinks.encode(profile)
        val parsed = LoginLinks.parse(encoded)

        assertNotNull(parsed)
        assertEquals(profile.server, parsed?.server)
        assertEquals(profile.username, parsed?.username)
        assertEquals(profile.password, parsed?.password)
        assertEquals("brutv", java.net.URI(encoded).scheme)
    }

    @Test
    fun nestedPlaylistLinksAndGetPhpUrlsAreParsed() {
        val playlist = "https://provider.example/list.m3u?token=a%2Bb%26c"
        val parsedPlaylist = LoginLinks.parse(LoginLinks.encode(SourceConfig(name = "Family", type = SourceType.M3U, playlistUrl = playlist)))
        assertEquals(SourceType.M3U, parsedPlaylist?.type)
        assertEquals(playlist, parsedPlaylist?.playlistUrl)

        val converted = LoginLinks.parse("https://provider.example/panel/get.php?username=one%2Btwo&password=secret%26value&type=m3u_plus")
        assertEquals(SourceType.XTREAM, converted?.type)
        assertEquals("https://provider.example/panel", converted?.server)
        assertEquals("one+two", converted?.username)
        assertEquals("secret&value", converted?.password)
    }

    @Test
    fun rejectsMalformedOrNonHttpSources() {
        assertNull(LoginLinks.parse("brutv://login?server=file%3A%2F%2Fhost&username=u&password=p"))
        assertNull(LoginLinks.parse("brutv://login?m3u=file%3A%2F%2F%2Fdata%2Fuser%2F0%2Fapp%2Fno_backup%2Fplaylists%2F00000000-0000-0000-0000-000000000000.m3u"))
        assertNull(LoginLinks.parse("https://"))
        assertNull(LoginLinks.parse("brutv://other?m3u=https%3A%2F%2Fprovider.example%2Flist.m3u"))

        try {
            LoginLinks.encode(
                SourceConfig(
                    name = "Imported",
                    type = SourceType.M3U,
                    playlistUrl = "file:///data/user/0/app/no_backup/playlists/00000000-0000-0000-0000-000000000000.m3u",
                ),
            )
            throw AssertionError("Expected local playlists to be excluded from share links")
        } catch (error: IllegalArgumentException) {
            assertEquals("Device-local playlists cannot be shared in a sign-in link.", error.message)
        }
    }

    @Test
    fun parsesTolerantLinkFormats() {
        val trailingSlash = LoginLinks.parse("brutv://login/?server=http%3A%2F%2Fiptv.example%3A8080&username=demo&password=pass")
        assertNotNull(trailingSlash)
        assertEquals("http://iptv.example:8080", trailingSlash?.server)
        assertEquals("demo", trailingSlash?.username)

        val singleSlash = LoginLinks.parse("brutv:/login?server=http%3A%2F%2Fiptv.example%3A8080&username=demo&password=pass")
        assertNotNull(singleSlash)
        assertEquals("demo", singleSlash?.username)

        val uppercase = LoginLinks.parse("BRUTV://LOGIN?server=http%3A%2F%2Fiptv.example%3A8080&username=demo&password=pass")
        assertNotNull(uppercase)

        val unencodedSpecialChars = LoginLinks.parse("brutv://login?server=http://iptv.example:8080&username=demo&password=pass{word}")
        assertNotNull(unencodedSpecialChars)
        assertEquals("pass{word}", unencodedSpecialChars?.password)

        val quoted = LoginLinks.parse("\"brutv://login?server=http%3A%2F%2Fiptv.example%3A8080&username=demo&password=pass\"")
        assertNotNull(quoted)
    }
}
