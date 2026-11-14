package com.example.pilah_foto

import android.accounts.Account
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.media.MediaScannerConnection
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var pendingDrivePickerResult: MethodChannel.Result? = null
    private val videoThumbnailExecutor = Executors.newFixedThreadPool(2)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pilah_foto/google_drive_picker",
        ).setMethodCallHandler { call, result ->
            if (call.method != "pickExistingDriveFolder") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val accountEmail = call.argument<String>("accountEmail")
            pickExistingDriveFolder(accountEmail, result)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pilah_foto/google_sign_in_diagnostics",
        ).setMethodCallHandler { call, result ->
            if (call.method != "getAndroidSignInDiagnostics") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val webClientIdResource = resources.getIdentifier(
                "default_web_client_id",
                "string",
                packageName,
            )
            result.success(
                mapOf(
                    "packageName" to packageName,
                    "signingSha1" to signingCertificateSha1(),
                    "defaultWebClientId" to
                        if (webClientIdResource == 0) {
                            null
                        } else {
                            getString(webClientIdResource)
                        },
                ),
            )
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pilah_foto/app_update",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceInfo" -> result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
                    ),
                )
                "canInstallApks" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        packageManager.canRequestPackageInstalls(),
                )
                "openInstallSettings" -> try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error(
                        "install_settings_unavailable",
                        error.message ?: "Unable to open install settings.",
                        null,
                    )
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("path")
                    if (apkPath.isNullOrBlank()) {
                        result.error(
                            "invalid_apk_path",
                            "The update APK path is missing.",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    val apkFile = File(apkPath)
                    if (!apkFile.isFile) {
                        result.error(
                            "apk_not_found",
                            "The downloaded update APK was not found.",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            result.error(
                                "install_permission_required",
                                "Install unknown apps permission is required.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        val apkUri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            apkFile,
                        )
                        val installIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(
                                apkUri,
                                "application/vnd.android.package-archive",
                            )
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(installIntent)
                        result.success(null)
                    } catch (error: ActivityNotFoundException) {
                        result.error(
                            "installer_unavailable",
                            error.message ?: "No package installer is available.",
                            null,
                        )
                    } catch (error: Exception) {
                        result.error(
                            "apk_install_failed",
                            error.message ?: "Unable to open the package installer.",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "loka_files/storage",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPublicDocumentsDirectory" -> result.success(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOCUMENTS,
                    ).absolutePath,
                )
                "scanRestoredFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error(
                            "invalid_file_path",
                            "The restored file path is missing.",
                            null,
                        )
                    } else {
                        MediaScannerConnection.scanFile(
                            this,
                            arrayOf(path),
                            null,
                            null,
                        )
                        result.success(null)
                    }
                }
                "getVideoThumbnail" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error(
                            "invalid_video_path",
                            "The video path is missing.",
                            null,
                        )
                    } else {
                        val videoFile = File(path)
                        if (!videoFile.isFile) {
                            result.error(
                                "video_not_found",
                                "The video file is unavailable.",
                                null,
                            )
                        } else {
                            videoThumbnailExecutor.execute {
                                val retriever = MediaMetadataRetriever()
                                var bitmap: Bitmap? = null
                                try {
                                    retriever.setDataSource(videoFile.absolutePath)
                                    bitmap = if (
                                        Build.VERSION.SDK_INT >=
                                            Build.VERSION_CODES.O_MR1
                                    ) {
                                        retriever.getScaledFrameAtTime(
                                            1_000_000L,
                                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                            480,
                                            480,
                                        )
                                    } else {
                                        retriever.getFrameAtTime(
                                            1_000_000L,
                                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                        )
                                    }
                                    val frame = bitmap ?: throw IllegalStateException(
                                        "No video frame is available.",
                                    )
                                    val thumbnailBytes = ByteArrayOutputStream().use {
                                        output ->
                                        frame.compress(
                                            Bitmap.CompressFormat.JPEG,
                                            82,
                                            output,
                                        )
                                        output.toByteArray()
                                    }
                                    val duration = retriever.extractMetadata(
                                        MediaMetadataRetriever.METADATA_KEY_DURATION,
                                    )?.toLongOrNull() ?: 0L
                                    Handler(Looper.getMainLooper()).post {
                                        result.success(
                                            mapOf(
                                                "bytes" to thumbnailBytes,
                                                "durationMilliseconds" to duration,
                                            ),
                                        )
                                    }
                                } catch (error: Exception) {
                                    Handler(Looper.getMainLooper()).post {
                                        result.error(
                                            "video_thumbnail_failed",
                                            error.message
                                                ?: "Unable to generate a video thumbnail.",
                                            null,
                                        )
                                    }
                                } finally {
                                    bitmap?.recycle()
                                    retriever.release()
                                }
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        videoThumbnailExecutor.shutdown()
        super.onDestroy()
    }

    private fun pickExistingDriveFolder(
        accountEmail: String?,
        result: MethodChannel.Result,
    ) {
        if (pendingDrivePickerResult != null) {
            result.error("picker_in_progress", "A Drive picker is already open.", null)
            return
        }
        pendingDrivePickerResult = result

        val requestBuilder = AuthorizationRequest.builder()
            // Google Picker grants access to selected folders under drive.file.
            .setRequestedScopes(
                listOf(Scope("https://www.googleapis.com/auth/drive.file")),
            )
            .setOptOutIncludingGrantedScopes(true)
            .setPrompt(AuthorizationRequest.Prompt.CONSENT)
            .addResourceParameter(
                AuthorizationRequest.ResourceParameter.PICKER_OAUTH_TRIGGER,
                "true",
            )
            .addResourceParameter(
                AuthorizationRequest.ResourceParameter.PICKER_ALLOW_FOLDER_SELECTION,
                "true",
            )
            .addResourceParameter(
                AuthorizationRequest.ResourceParameter.PICKER_MIMETYPES,
                "application/vnd.google-apps.folder",
            )
        if (!accountEmail.isNullOrBlank()) {
            requestBuilder.setAccount(Account(accountEmail, "com.google"))
        }

        Identity.getAuthorizationClient(this)
            .authorize(requestBuilder.build())
            .addOnSuccessListener { authorizationResult ->
                if (!authorizationResult.hasResolution()) {
                    finishDrivePickerError(
                        "picker_not_opened",
                        "Google did not open the Drive folder picker.",
                    )
                    return@addOnSuccessListener
                }
                try {
                    @Suppress("DEPRECATION")
                    startIntentSenderForResult(
                        authorizationResult.pendingIntent!!.intentSender,
                        DRIVE_PICKER_REQUEST_CODE,
                        null,
                        0,
                        0,
                        0,
                    )
                } catch (error: Exception) {
                    finishDrivePickerError(
                        "picker_launch_failed",
                        error.message ?: "Unable to open the Google Drive picker.",
                    )
                }
            }
            .addOnFailureListener { error ->
                finishDrivePickerError(
                    "picker_authorization_failed",
                    error.message ?: "Google Drive authorization failed.",
                )
            }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        if (requestCode == DRIVE_PICKER_REQUEST_CODE) {
            if (resultCode != Activity.RESULT_OK || data == null) {
                pendingDrivePickerResult?.success(null)
                pendingDrivePickerResult = null
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            try {
                val authorizationResult =
                    Identity.getAuthorizationClient(this)
                        .getAuthorizationResultFromIntent(data)
                val pickedFileIds = authorizationResult.tokenResponseParams
                    ?.getString("picked_file_ids")
                val accessToken = authorizationResult.accessToken
                if (pickedFileIds.isNullOrBlank() || accessToken.isNullOrBlank()) {
                    pendingDrivePickerResult?.success(null)
                } else {
                    pendingDrivePickerResult?.success(
                        mapOf(
                            "pickedFileIds" to pickedFileIds,
                            "accessToken" to accessToken,
                        ),
                    )
                }
            } catch (error: Exception) {
                finishDrivePickerError(
                    "picker_result_failed",
                    error.message ?: "Unable to read the selected Drive folder.",
                )
            } finally {
                pendingDrivePickerResult = null
            }
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun finishDrivePickerError(code: String, message: String) {
        pendingDrivePickerResult?.error(code, message, null)
        pendingDrivePickerResult = null
    }

    @Suppress("DEPRECATION")
    private fun signingCertificateSha1(): String? {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            ).signingInfo?.apkContentsSigners
        } else {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNATURES,
            ).signatures
        }
        val signature = signatures?.firstOrNull() ?: return null
        return MessageDigest.getInstance("SHA-1")
            .digest(signature.toByteArray())
            .joinToString(":") { "%02X".format(it.toInt() and 0xFF) }
    }

    private companion object {
        const val DRIVE_PICKER_REQUEST_CODE = 0xD12
    }
}
