plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
}

/** `-PcrokRelayUrl=https://<deployment>.convex.cloud`; empty means the build type's default below. */
val relayUrlOverride: String? = providers.gradleProperty("crokRelayUrl").orNull?.trim()?.takeIf { it.isNotEmpty() }

fun quoted(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "dev.chenli.crok.mobile"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.chenli.crok.mobile"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            // 10.0.2.2 is the Android emulator's alias for the host, where `npx convex dev` serves the local relay.
            buildConfigField("String", "RELAY_URL", quoted(relayUrlOverride ?: "http://10.0.2.2:3210"))
            buildConfigField("boolean", "DEMO_ALLOWED", "true")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("String", "RELAY_URL", quoted(relayUrlOverride ?: ""))
            buildConfigField("boolean", "DEMO_ALLOWED", "false")
            // Signed with the debug key so `assembleRelease` produces an installable APK; use a real key to ship.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all { test ->
                test.maxHeapSize = "2g"
                // Robolectric reaches into FileDescriptor internals, closed by default on JDK 17+.
                test.jvmArgs(
                    "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
                    "--add-opens=java.base/java.io=ALL-UNNAMED",
                    "--add-opens=java.base/java.lang=ALL-UNNAMED",
                )
                // The relay integration test runs only when asked: CROK_RELAY_IT=1 ./gradlew :app:testDebugUnitTest
                test.environment("CROK_RELAY_IT", providers.environmentVariable("CROK_RELAY_IT").orElse("").get())
                test.environment("CROK_NPX", providers.environmentVariable("CROK_NPX").orElse("").get())
                test.systemProperty("crok.relayDir", rootProject.layout.projectDirectory.dir("../../relay").asFile.canonicalPath)
                test.systemProperty("crok.relayUrl", providers.environmentVariable("CROK_RELAY_URL").orElse("http://127.0.0.1:3210").get())
            }
        }
    }

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/LICENSE*", "/META-INF/NOTICE*")
    }

    lint {
        abortOnError = true
        checkDependencies = false
        // Version-bump nags are not actionable in a build that pins versions in the catalog on purpose.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "OldTargetApi")
        // The Convex and JNA AARs use the `@aar` notation, which a version catalog entry cannot express.
        disable += "UseTomlInstead"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.addAll("-opt-in=androidx.compose.material3.ExperimentalMaterial3Api")
    }
}


dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.browser)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.gms.code.scanner)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    // Convex: the AAR with its own dependencies, and the JNA build that supports 16 KB memory pages.
    implementation("dev.convex:android-convexmobile:${libs.versions.convex.get()}@aar") { isTransitive = true }
    implementation("net.java.dev.jna:jna:${libs.versions.jna.get()}@aar")

    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)
}
