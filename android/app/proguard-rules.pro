# Reglas R8/ProGuard para InútilTV (CameraX + MLKit Barcode + MobileScanner)
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }
-keep class androidx.camera.** { *; }
-keep class dev.steenbakker.mobile_scanner.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn androidx.camera.**
