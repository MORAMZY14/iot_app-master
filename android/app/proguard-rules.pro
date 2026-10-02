# flutter_blue_plus 1.36.x uses reflected fields in its Android bridge.
# https://pub.dev/packages/flutter_blue_plus/versions/1.36.8#android-proguard
-keep class com.lib.flutter_blue_plus.* { *; }

# Keep JNI entry-point names used by local model libraries. Other Firebase,
# Flutter, and inference rules come from the libraries' consumer ProGuard files.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
