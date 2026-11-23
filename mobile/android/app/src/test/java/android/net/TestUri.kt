package android.net

import android.os.Parcel

internal fun testUri(url: String = "https://provider.example/live.m3u8"): Uri = object : Uri() {
    override fun isHierarchical(): Boolean = true
    override fun isRelative(): Boolean = false
    override fun getScheme(): String = "https"
    override fun getSchemeSpecificPart(): String = "//provider.example/live.m3u8"
    override fun getEncodedSchemeSpecificPart(): String = "//provider.example/live.m3u8"
    override fun getAuthority(): String = "provider.example"
    override fun getEncodedAuthority(): String = "provider.example"
    override fun getUserInfo(): String? = null
    override fun getEncodedUserInfo(): String? = null
    override fun getHost(): String = "provider.example"
    override fun getPort(): Int = -1
    override fun getPath(): String = "/live.m3u8"
    override fun getEncodedPath(): String = "/live.m3u8"
    override fun getQuery(): String? = null
    override fun getEncodedQuery(): String? = null
    override fun getFragment(): String? = null
    override fun getEncodedFragment(): String? = null
    override fun getPathSegments(): MutableList<String> = mutableListOf("live.m3u8")
    override fun getLastPathSegment(): String = "live.m3u8"
    override fun buildUpon(): Builder = throw UnsupportedOperationException()
    override fun toString(): String = url
    override fun describeContents(): Int = 0
    override fun writeToParcel(dest: Parcel, flags: Int) {}
}
