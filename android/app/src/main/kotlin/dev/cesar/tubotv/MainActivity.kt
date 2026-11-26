package dev.cesar.tubotv

import android.app.UiModeManager
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
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
import java.security.MessageDigest
import java.util.zip.ZipFile

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
                "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
                "openInstallUnknownAppsSettings" -> openInstallUnknownAppsSettings(result)
                "verifyPackage" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("invalid_path", "Falta la ruta del APK.", null)
                        return@setMethodCallHandler
                    }
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("missing_file", "El archivo no existe.", null)
                        return@setMethodCallHandler
                    }
                    result.success(verifyPackageDetails(file))
                }
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
                "getSystemProxy" -> result.success(readSystemHttpProxy())
                else -> result.notImplemented()
            }
        }
    }

    private fun primaryInstallAbi(): String = Build.SUPPORTED_ABIS.firstOrNull() ?: ""

    private fun readSystemHttpProxy(): String {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val cm = getSystemService(CONNECTIVITY_SERVICE) as? ConnectivityManager
                val proxyInfo = cm?.defaultProxy
                val host = proxyInfo?.host?.trim().orEmpty()
                val port = proxyInfo?.port ?: -1
                if (host.isNotEmpty() && port in 1..65535) {
                    return "$host:$port"
                }
            }
        } catch (_: Exception) {
        }
        return try {
            val host = System.getProperty("http.proxyHost")?.trim().orEmpty()
            val portStr = System.getProperty("http.proxyPort")?.trim().orEmpty()
            val port = portStr.toIntOrNull() ?: 3128
            if (host.isNotEmpty() && port in 1..65535) "$host:$port" else ""
        } catch (_: Exception) {
            ""
        }
    }

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

    private fun getCertificateDigests(signatures: Array<android.content.pm.Signature>?): List<String> {
        if (signatures == null || signatures.isEmpty()) return emptyList()
        val md = MessageDigest.getInstance("SHA-256")
        return signatures.map { sig ->
            md.reset()
            val digest = md.digest(sig.toByteArray())
            digest.joinToString("") { "%02x".format(it) }
        }
    }

    private fun getInstalledSignatures(): List<String> {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val pi = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                val signingInfo = pi.signingInfo
                if (signingInfo != null) {
                    val sigs = if (signingInfo.hasMultipleSigners()) {
                        signingInfo.apkContentsSigners
                    } else {
                        signingInfo.signingCertificateHistory
                    }
                    getCertificateDigests(sigs)
                } else emptyList()
            } else {
                @Suppress("DEPRECATION")
                val pi = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                getCertificateDigests(pi.signatures)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error reading installed app signatures", e)
            emptyList()
        }
    }

    private fun getApkSignatures(file: File): List<String> {
        return try {
            val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageManager.getPackageArchiveInfo(
                    file.absolutePath,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageArchiveInfo(file.absolutePath, PackageManager.GET_SIGNATURES)
            }
            if (pi == null) return emptyList()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val signingInfo = pi.signingInfo
                if (signingInfo != null) {
                    val sigs = if (signingInfo.hasMultipleSigners()) {
                        signingInfo.apkContentsSigners
                    } else {
                        signingInfo.signingCertificateHistory
                    }
                    getCertificateDigests(sigs)
                } else {
                    @Suppress("DEPRECATION")
                    getCertificateDigests(pi.signatures)
                }
            } else {
                @Suppress("DEPRECATION")
                getCertificateDigests(pi.signatures)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error reading APK signatures", e)
            emptyList()
        }
    }

    private fun getApkSupportedAbis(file: File): Set<String> {
        val abis = mutableSetOf<String>()
        try {
            ZipFile(file).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    val name = entry.name
                    if (name.startsWith("lib/") && name.endsWith(".so")) {
                        val parts = name.split("/")
                        if (parts.size >= 2 && parts[1].isNotEmpty()) {
                            abis.add(parts[1])
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error reading APK zip entries for ABIs", e)
        }
        return abis
    }

    private fun verifyPackageDetails(file: File): Map<String, Any?> {
        val archiveInfo: PackageInfo? = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageArchiveInfo(
                    file.absolutePath,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageArchiveInfo(file.absolutePath, 0)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Error pre-validating APK archive", error)
            null
        }

        if (archiveInfo == null) {
            return mapOf(
                "valid" to false,
                "errorCode" to "corrupt_apk",
                "errorMessage" to "El paquete descargado está dañado o incompleto.",
            )
        }

        if (archiveInfo.packageName != packageName) {
            return mapOf(
                "valid" to false,
                "errorCode" to "wrong_package",
                "errorMessage" to "El paquete (${archiveInfo.packageName}) no corresponde a esta app ($packageName).",
            )
        }

        val apkAbis = getApkSupportedAbis(file)
        val deviceAbis = Build.SUPPORTED_ABIS.toList()
        val isAbiCompatible = apkAbis.isEmpty() || apkAbis.any { it in deviceAbis }

        if (!isAbiCompatible) {
            return mapOf(
                "valid" to false,
                "errorCode" to "incompatible_abi",
                "errorMessage" to "El paquete está compilado para (${apkAbis.joinToString()}) y este dispositivo requiere (${deviceAbis.joinToString()}).",
                "apkAbis" to apkAbis.toList(),
                "deviceAbis" to deviceAbis,
            )
        }

        val installedSignatures = getInstalledSignatures()
        val apkSignatures = getApkSignatures(file)
        val signaturesMatch = installedSignatures.isEmpty() || apkSignatures.isEmpty() ||
            installedSignatures.any { it in apkSignatures }

        if (!signaturesMatch) {
            return mapOf(
                "valid" to false,
                "errorCode" to "signature_mismatch",
                "errorMessage" to "La clave de firma del paquete no coincide con la versión instalada en el dispositivo.",
                "installedSignatures" to installedSignatures,
                "apkSignatures" to apkSignatures,
            )
        }

        val installedVersionCode = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageManager.getPackageInfo(packageName, 0).longVersionCode
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0).versionCode.toLong()
            }
        } catch (_: Exception) {
            -1L
        }

        val apkVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            archiveInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            archiveInfo.versionCode.toLong()
        }

        val isDowngrade = installedVersionCode > 0L && apkVersionCode < installedVersionCode
        val isSameVersion = installedVersionCode > 0L && apkVersionCode == installedVersionCode
        val isUpgrade = installedVersionCode > 0L && apkVersionCode > installedVersionCode

        if (isDowngrade) {
            return mapOf(
                "valid" to false,
                "errorCode" to "downgrade_rejected",
                "errorMessage" to "No se puede degradar la versión: el paquete (code $apkVersionCode) es inferior a la versión instalada ($installedVersionCode).",
                "apkVersionCode" to apkVersionCode,
                "installedVersionCode" to installedVersionCode,
            )
        }

        return mapOf(
            "valid" to true,
            "packageName" to archiveInfo.packageName,
            "versionName" to (archiveInfo.versionName ?: ""),
            "versionCode" to apkVersionCode,
            "installedVersionCode" to installedVersionCode,
            "isSameVersion" to isSameVersion,
            "isUpgrade" to isUpgrade,
            "isDowngrade" to isDowngrade,
            "apkAbis" to apkAbis.toList(),
            "deviceAbis" to deviceAbis,
            "isAbiCompatible" to true,
            "signaturesMatch" to true,
        )
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

        val verification = verifyPackageDetails(file)
        val isValid = verification["valid"] as? Boolean ?: false
        if (!isValid) {
            val code = verification["errorCode"] as? String ?: "invalid_package"
            val msg = verification["errorMessage"] as? String ?: "El paquete no es válido para este dispositivo."
            runCatching { file.delete() }
            result.error(code, msg, verification)
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
            .apply {
                clipData = ClipData.newRawUri("", apkUri)
            }
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
