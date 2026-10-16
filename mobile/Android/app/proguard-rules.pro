# Convex's client talks to its Rust core through JNA (uniffi): keep the bindings and JNA itself.
-keep class dev.convex.android.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**

# kotlinx.serialization: keep the generated serializers of the app's wire models.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class dev.chenli.crok.mobile.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class dev.chenli.crok.mobile.**$$serializer { *; }
