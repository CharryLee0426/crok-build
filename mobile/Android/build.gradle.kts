// AGP 9 compiles Kotlin itself (built-in Kotlin); the Kotlin plugins below pin the compiler version for the whole build.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.roborazzi) apply false
}
