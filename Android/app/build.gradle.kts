import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.theagilemonkeys.shepherdr.remote"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.theagilemonkeys.shepherdr.remote"
        // Android 10 is the first with TLS 1.3, which the Mac's relay requires.
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    // The upload key signs release builds for Google Play, which signs them again with the app's
    // own key. Its path and passwords go in Android/keystore.properties, which git ignores:
    //
    //     storeFile=/path/to/upload.jks
    //     storePassword=…
    //     keyAlias=upload
    //     keyPassword=…
    //
    // Without it, release builds come out unsigned.
    val keystore = rootProject.file("keystore.properties").takeIf { it.exists() }?.let { file ->
        Properties().apply { file.inputStream().use { load(it) } }
    }
    signingConfigs {
        if (keystore != null) {
            create("upload") {
                storeFile = file(keystore.getProperty("storeFile"))
                storePassword = keystore.getProperty("storePassword")
                keyAlias = keystore.getProperty("keyAlias")
                keyPassword = keystore.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Shepherdr dev")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("upload")
            resValue("string", "app_name", "Shepherdr")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// The fonts and arcade pictures the Mac and iPhone apps use, from where they live in this repository,
// renamed as Android's resources want them.
val repository = rootDir.parentFile
val sharedResources = tasks.register<Sync>("sharedResources") {
    into(layout.buildDirectory.dir("generated/shared-res"))
    from(repository.resolve("Sources/ShepherdrTerminalUI/Resources/Fonts")) {
        include("FiraCode-Regular.ttf", "FiraCode-Medium.ttf", "FiraCode-SemiBold.ttf", "FiraCode-Bold.ttf")
        rename { it.lowercase().replace('-', '_') }
        into("font")
    }
    val assets = repository.resolve("iOS/ShepherdrRemote/Assets.xcassets")
    from(assets.resolve("ArcadeDog.imageset/icon.png")) { rename { "arcade_dog.png" }; into("drawable-nodpi") }
    from(assets.resolve("ArcadeTitle.imageset/header.png")) { rename { "arcade_title.png" }; into("drawable-nodpi") }
}
// Fira Code's license ships in the app, as it does in the Mac's.
val sharedAssets = tasks.register<Sync>("sharedAssets") {
    into(layout.buildDirectory.dir("generated/shared-assets"))
    from(repository.resolve("Sources/ShepherdrTerminalUI/Resources/Fonts/FiraCode-OFL.txt")) { into("licenses") }
}
android.sourceSets["main"].res.srcDir(sharedResources.map { it.destinationDir })
android.sourceSets["main"].assets.srcDir(sharedAssets.map { it.destinationDir })
tasks.named("preBuild") { dependsOn(sharedResources, sharedAssets) }

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.okhttp)
    implementation(libs.serialization.json)
    implementation(libs.code.scanner)
    implementation(libs.termux.emulator)
    implementation(libs.termux.view)
    debugImplementation(libs.compose.ui.tooling)

    testImplementation(libs.junit)
}
