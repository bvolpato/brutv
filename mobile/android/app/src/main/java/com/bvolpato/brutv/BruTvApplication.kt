package com.bvolpato.brutv

import android.app.ActivityManager
import android.app.Application
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.disk.DiskCache
import coil.memory.MemoryCache
import com.bvolpato.brutv.data.CatalogRepository
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

/** Application-scoped Coil ImageLoader tuned for low-RAM TV sticks and large catalogs. */
class BruTvApplication : Application(), ImageLoaderFactory {
    override fun newImageLoader(): ImageLoader {
        val isLowRam = (getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
            ?.isLowRamDevice == true
        val isTv = (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)
            ?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        val artworkDispatcher = Dispatcher().apply {
            maxRequests = if (isLowRam) 8 else 16
            maxRequestsPerHost = 4
        }
        val artworkClient = OkHttpClient.Builder()
            .dispatcher(artworkDispatcher)
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS)
            .callTimeout(15, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .addInterceptor { chain ->
                val request = chain.request()
                val withUserAgent = if (request.header("User-Agent") == null) {
                    request.newBuilder().header("User-Agent", CatalogRepository.USER_AGENT).build()
                } else {
                    request
                }
                chain.proceed(withUserAgent)
            }
            .build()
        return ImageLoader.Builder(this)
            .okHttpClient(artworkClient)
            .allowRgb565(true)
            .memoryCache {
                MemoryCache.Builder(this)
                    .maxSizePercent(if (isLowRam) 0.10 else 0.18)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(File(cacheDir, "brutv_artwork"))
                    .maxSizeBytes(if (isLowRam) 64L * 1024 * 1024 else 192L * 1024 * 1024)
                    .build()
            }
            .crossfade(if (isTv) 0 else 180)
            .build()
    }
}
