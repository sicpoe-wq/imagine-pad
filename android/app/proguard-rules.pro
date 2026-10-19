# Imagine Pad R8 rules. Flutter and each plugin ship their own consumer rules;
# these cover what is left.

# Flutter engine references Play Core (deferred components) which we don't use.
-dontwarn com.google.android.play.core.**

# flutter_secure_storage (Android Keystore / Tink).
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**

# image_picker / file_picker / share_plus use FileProvider + reflection-free
# APIs; keep their plugin classes so method-channel registration survives.
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class dev.fluttercommunity.plus.share.** { *; }

# gal (save to gallery)
-keep class studio.midoridesign.gal.** { *; }

# Kotlin coroutines metadata used by some plugins
-dontwarn kotlinx.coroutines.**
