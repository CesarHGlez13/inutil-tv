package dev.cesar.tubotv

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * Exposes the runtime Android package name and APK signing certificate SHA-256
 * so the Inutix Level 2 server license-ticket endpoint can reject repackaged
 * or re-signed unofficial APK builds.
 */
class InutixAppIntegrityPlugin(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "inutil_tv/app_integrity"

        fun register(messenger: BinaryMessenger, context: Context): MethodChannel {
            val channel = MethodChannel(messenger, CHANNEL_NAME)
            channel.setMethodCallHandler(InutixAppIntegrityPlugin(context.applicationContext))
            return channel
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getIntegrityInfo" -> {
                try {
                    result.success(readIntegrityInfo())
                } catch (t: Throwable) {
                    result.error("INTEGRITY_ERROR", t.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun readIntegrityInfo(): Map<String, Any?> {
        val pkgName = context.packageName
        val certSha256 = readSigningCertSha256(pkgName)
        return mapOf(
            "packageName" to pkgName,
            "apkCertSha256" to certSha256,
        )
    }

    @Suppress("DEPRECATION")
    private fun readSigningCertSha256(packageName: String): String {
        val pm = context.packageManager
        val certBytes: ByteArray? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            val signingInfo = info.signingInfo
            val signatures =
                signingInfo?.apkContentsSigners?.takeIf { it.isNotEmpty() }
                    ?: signingInfo?.signingCertificateHistory?.takeIf { it.isNotEmpty() }
            signatures?.firstOrNull()?.toByteArray()
                ?: pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                    .signatures?.firstOrNull()?.toByteArray()
        } else {
            val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
            info.signatures?.firstOrNull()?.toByteArray()
        }

        if (certBytes == null || certBytes.isEmpty()) {
            return ""
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(certBytes)
        return digest.joinToString("") { byte -> "%02x".format(byte) }
    }
}
