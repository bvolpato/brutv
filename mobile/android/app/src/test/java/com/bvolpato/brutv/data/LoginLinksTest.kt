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
    fun parsesIosUniversalJoinLinksAndDecodesNestedValuesOnce() {
        val xtream = LoginLinks.parse(
            "https://bvolpato.github.io/brutv/join.html?server=https%3A%2F%2Fprovider.example%2Fpanel&username=jo%C3%A3o%2Bone%26two&password=secret%20%2B%20%26%3D%3F%23%25",
        )
        assertEquals(SourceType.XTREAM, xtream?.type)
        assertEquals("https://provider.example/panel", xtream?.server)
        assertEquals("joão+one&two", xtream?.username)
        assertEquals("secret + &=?#%", xtream?.password)

        val playlist = "https://provider.example/list.m3u?token=a%2Bb&name=A%20B"
        val m3u = LoginLinks.parse(
            "https://bvolpato.github.io/brutv/join.html?m3u=https%3A%2F%2Fprovider.example%2Flist.m3u%3Ftoken%3Da%252Bb%26name%3DA%2520B",
        )
        assertEquals(SourceType.M3U, m3u?.type)
        assertEquals(playlist, m3u?.playlistUrl)
    }

    @Test
    fun onlyParsesSupportedUniversalJoinRouteAndRejectsMalformedJoinPayloads() {
        val incomplete = "https://bvolpato.github.io/brutv/join.html?server=https%3A%2F%2Fprovider.example&username=family"
        assertNull(LoginLinks.parse(incomplete))
        assertNull(LoginLinks.parse("https://bvolpato.github.io/brutv/join.html?m3u=file%3A%2F%2F%2Fprivate%2Flist.m3u"))

        val unrelatedWebPage = "https://provider.example/join.html?server=https%3A%2F%2Fpanel.example&username=family&password=secret"
        val parsedPage = LoginLinks.parse(unrelatedWebPage)
        assertEquals(SourceType.M3U, parsedPage?.type)
        assertEquals(unrelatedWebPage, parsedPage?.playlistUrl)
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
