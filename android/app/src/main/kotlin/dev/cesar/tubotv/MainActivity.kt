package dev.cesar.tubotv

import android.app.UiModeManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "InutilTvMainActivity"
        private const val APP_UPDATE_CHANNEL = "inutil_tv/app_update"
        private const val DEVICE_CHANNEL = "inutil_tv/device"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_UPDATE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "primaryAbi" -> result.success(primaryInstallAbi())
                "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
                "openInstallUnknownAppsSettings" -> openInstallUnknownAppsSettings(result)
                "installPackage" -> installDownloadedPackage(call, result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    runOnUiThread {
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(true)
                }
                "getBrightness" -> {
                    val lp = window.attributes
                    val current = if (lp.screenBrightness >= 0f) {
                        lp.screenBrightness.toDouble()
                    } else {
                        try {
                            val sys = Settings.System.getInt(
                                contentResolver,
                                Settings.System.SCREEN_BRIGHTNESS,
                            )
                            (sys.toDouble() / 255.0).coerceIn(0.05, 1.0)
                        } catch (_: Exception) {
                            0.5
                        }
                    }
                    result.success(current)
                }
                "setBrightness" -> {
                    val value = (call.argument<Double>("value") ?: 0.5).toFloat().coerceIn(0.02f, 1.0f)
                    runOnUiThread {
                        val lp = window.attributes
                        lp.screenBrightness = value
                        window.attributes = lp
                    }
                    result.success(true)
                }
                "resetBrightness" -> {
                    runOnUiThread {
                        val lp = window.attributes
                        lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        window.attributes = lp
                    }
                    result.success(true)
                }
                "isAndroidTv" -> result.success(detectAndroidTv())
                else -> result.notImplemented()
            }
        }
    }

    private fun primaryInstallAbi(): String = Build.SUPPORTED_ABIS.firstOrNull() ?: ""

    private fun detectAndroidTv(): Boolean {
        val uiMode = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        val pm = packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) {
            return true
        }
        if (!pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)) {
            return true
        }
        return false
    }

    private fun canRequestPackageInstalls(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun openInstallUnknownAppsSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(true)
            return
        }
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            Log.w(TAG, "Unknown-sources settings unavailable", error)
            result.success(false)
        }
    }

    private fun installDownloadedPackage(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("invalid_path", "Falta la ruta del APK.", null)
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() <= 0L) {
            result.error(
                "missing_file",
                "El paquete descargado ya no existe en el almacenamiento.",
                null,
            )
            return
        }
        val apkUri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (error: IllegalArgumentException) {
            result.error(
                "unshared_path",
                "El paquete descargado está fuera de las carpetas compartidas con el instalador.",
                null,
            )
            return
        }
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apkUri, "application/vnd.android.package-archive")
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        try {
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            Log.w(TAG, "Package installer unavailable", error)
            result.error(
                "no_installer",
                "No hay ninguna aplicación que pueda instalar este paquete.",
                null,
            )
        }
    }
}
