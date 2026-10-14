// ChatFort Crowd mesh: multi-hop Bluetooth LE messaging without internet.
// Platform APIs only (JCA crypto, Android Bluetooth, Android Keystore).
plugins {
    id("com.android.library")
    kotlin("android")
}

android {
    namespace = "chat.simplex.mesh"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    testImplementation("junit:junit:4.13.2")
    // android.jar only has stubs of org.json; the real one for JVM unit tests.
    testImplementation("org.json:json:20231013")
}
