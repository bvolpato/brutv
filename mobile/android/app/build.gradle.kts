import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.io.File
import java.util.Properties

val releaseSigningPropertiesPath = providers.environmentVariable("BRUTV_ANDROID_SIGNING_PROPERTIES").orNull
    ?: "${System.getProperty("user.home")}/.config/brutv/android/keystore.properties"
val releaseSigningPropertiesFile = file(releaseSigningPropertiesPath)
val releaseSigningProperties = Properties().apply {
    if (releaseSigningPropertiesFile.isFile) {
        releaseSigningPropertiesFile.inputStream().use(::load)
    }
}
val releaseSigningValues = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .associateWith { releaseSigningProperties.getProperty(it)?.trim().orEmpty() }
val releaseStoreFile = releaseSigningValues["storeFile"]
    ?.takeIf(String::isNotEmpty)
    ?.let(::File)
val productionSigningConfigured = releaseSigningValues.values.all(String::isNotBlank) &&
    releaseStoreFile?.isFile == true
val brutvMinimumSdk = providers.gradleProperty("brutvMinSdk").orNull?.toInt() ?: 23

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.bvolpato.brutv"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.bvolpato.brutv"
        minSdk = brutvMinimumSdk
        targetSdk = 36
        versionCode = 2
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (productionSigningConfigured) {
            create("production") {
                storeFile = releaseStoreFile!!
                storePassword = releaseSigningValues.getValue("storePassword")
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (productionSigningConfigured) {
                signingConfig = signingConfigs.getByName("production")
            }
        }
        create("preview") {
            initWith(getByName("release"))
            signingConfig = getByName("debug").signingConfig
            matchingFallbacks += "release"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    testOptions { unitTests.isReturnDefaultValues = true }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

gradle.taskGraph.whenReady {
    val releasePackagingTasks = setOf(
        "assembleRelease",
        "bundleRelease",
        "installRelease",
        "packageRelease",
        "signReleaseBundle",
    )
    if (allTasks.any { it.path.startsWith(":app:") && it.name in releasePackagingTasks } &&
        !productionSigningConfigured
    ) {
        throw GradleException(
            "Production signing is required for Android release packages. Configure " +
                "BRUTV_ANDROID_SIGNING_PROPERTIES or ~/.config/brutv/android/keystore.properties.",
        )
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.13.2")

    val media3 = "1.11.1"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")
    implementation("androidx.media3:media3-exoplayer-dash:$media3")
    implementation("androidx.media3:media3-ui:$media3")
    implementation("androidx.media3:media3-session:$media3")

    val camera = "1.6.2"
    implementation("androidx.camera:camera-camera2:$camera")
    implementation("androidx.camera:camera-lifecycle:$camera")
    implementation("androidx.camera:camera-view:$camera")
    implementation("com.google.zxing:core:3.5.3")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
