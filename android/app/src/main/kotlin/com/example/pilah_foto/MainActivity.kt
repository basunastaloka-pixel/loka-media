package com.example.pilah_foto

import android.accounts.Account
import android.app.Activity
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var pendingDrivePickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pilah_foto/google_sign_in_diagnostics",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getSigningDetails") {
                result.success(
                    mapOf(
                        "packageName" to packageName,
                        "sha1" to signingCertificateSha1(),
                    ),
                )
            } else {
                result.notImplemented()
            }
        }
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

    private fun signingCertificateSha1(): String? {
        val certificate = signingCertificateBytes() ?: return null
        val digest = MessageDigest.getInstance("SHA-1").digest(certificate)
        return digest.joinToString(":") { byte ->
            "%02X".format(byte.toInt() and 0xFF)
        }
    }

    @Suppress("DEPRECATION")
    private fun signingCertificateBytes(): ByteArray? {
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNATURES,
            )
        }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners?.firstOrNull()?.toByteArray()
        } else {
            packageInfo.signatures?.firstOrNull()?.toByteArray()
        }
    }

    private companion object {
        const val DRIVE_PICKER_REQUEST_CODE = 0xD12
    }
}
