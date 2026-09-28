package com.nous.gundam.gundam_pos

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands a staged APK to Android's package installer, so the PRD Upgrade Client
 * SOP (4.33a) can do an IN-PLACE install: the operator confirms it in the
 * system dialog and Android keeps the app data directory (local DB + config).
 *
 * Mirrors the printer channels: every outcome is a typed `{state, detail}` map,
 * never a thrown PlatformException, so a failed upgrade can never kill a sale.
 * States: ready | unsupported
 *
 * The APK is exposed as a `content://<applicationId>.fileprovider/apk/...` URI
 * with a read grant (see res/xml/file_paths.xml) rather than a world readable
 * file path. The Dart side verifies the SHA-256 BEFORE calling this.
 */
class ApkInstallChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "gundam/update"
        const val APK_MIME = "application/vnd.android.package-archive"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> install(call.argument<String>("path"), result)
            else -> result.notImplemented()
        }
    }

    private fun install(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.success(failure("unsupported", "No APK path given."))
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() <= 0L) {
            result.success(failure("unsupported", "APK not found at $path"))
            return
        }
        try {
            val uri: Uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            result.success(mapOf("state" to "ready", "detail" to "Installer opened for ${file.name}. Confirm the in-place update."))
        } catch (t: Throwable) {
            result.success(failure("unsupported", "Cannot open the installer for ${file.name}: ${t.message}"))
        }
    }

    private fun failure(state: String, detail: String?): Map<String, Any?> =
        mapOf("state" to state, "detail" to (detail ?: state))
}
