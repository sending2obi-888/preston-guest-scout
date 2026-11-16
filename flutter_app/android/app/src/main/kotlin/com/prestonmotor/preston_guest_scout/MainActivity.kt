@file:Suppress("DEPRECATION")

package com.prestonmotor.preston_guest_scout

import android.accounts.Account
import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.UserRecoverableAuthException
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "com.prestonmotor.scout/launcher_widget"
        const val AUTH_CHANNEL = "com.prestonmotor.scout/google_auth"
        const val PREFS_NAME = "preston_scout_widget_prefs"
        const val KEY_RECENT_TEN_JSON = "recent_ten_guests_json"
        const val EXTRA_GUEST_ID = "extra_guest_id"
        const val EXTRA_SCHEDULED_SLOT = "extra_scheduled_slot"
        const val STORE_FILENAME = "preston_scout_store.json"

        private const val REQ_GOOGLE_SIGN_IN = 9001
        private const val REQ_GOOGLE_CONSENT = 9002
        private const val DEFAULT_DRIVE_SCOPE = "https://www.googleapis.com/auth/drive"
    }

    private var methodChannel: MethodChannel? = null
    private var authChannel: MethodChannel? = null
    private var pendingLaunchGuestId: String? = null
    private var pendingScheduledSlot: String? = null
    private var pendingOAuthRedirectUri: String? = null

    private var pendingSignInResult: MethodChannel.Result? = null
    private var pendingDriveScope: String = DEFAULT_DRIVE_SCOPE
    private var pendingConsentAccount: GoogleSignInAccount? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DailySearchAlarmReceiver.scheduleTwiceDailyAlarms(this)
        handleIncomingIntent(intent, isColdStart = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent, isColdStart = false)
    }

    private fun handleIncomingIntent(intent: Intent?, isColdStart: Boolean) {
        if (intent == null) return

        val data = intent.data
        if (data != null &&
            (data.host == "oauth2redirect" || data.path?.contains("oauth2redirect") == true)
        ) {
            val uriStr = data.toString()
            if (!isColdStart && authChannel != null) {
                authChannel?.invokeMethod("onOAuthRedirect", uriStr)
            } else {
                pendingOAuthRedirectUri = uriStr
            }
            return
        }

        val slot = intent.getStringExtra(EXTRA_SCHEDULED_SLOT)
        if (!slot.isNullOrBlank()) {
            if (!isColdStart && methodChannel != null) {
                methodChannel?.invokeMethod("runScheduledDailySearch", slot)
            } else {
                pendingScheduledSlot = slot
            }
        }

        extractGuestIdFromIntent(intent)?.let { guestId ->
            if (!isColdStart && methodChannel != null) {
                methodChannel?.invokeMethod("openGuestMatches", guestId)
            } else {
                pendingLaunchGuestId = guestId
            }
        }
    }

    private fun extractGuestIdFromIntent(intent: Intent?): String? {
        if (intent == null) return null
        val fromExtra = intent.getStringExtra(EXTRA_GUEST_ID)
        if (!fromExtra.isNullOrBlank()) return fromExtra
        val data = intent.data
        if (data != null && data.scheme == "prestonscout" && data.host == "guest") {
            return data.pathSegments.firstOrNull()
        }
        return null
    }

    private fun buildGoogleSignInClient(driveScope: String, webClientId: String?): GoogleSignInClient {
        val builder = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestProfile()
            .requestScopes(Scope(driveScope))
        if (!webClientId.isNullOrBlank()) {
            builder.requestIdToken(webClientId.trim())
        }
        return GoogleSignIn.getClient(this, builder.build())
    }

    private fun computeSigningSha1(): String {
        return try {
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val pkgInfo = packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES
                )
                pkgInfo.signingInfo?.apkContentsSigners ?: emptyArray()
            } else {
                val pkgInfo = packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNATURES
                )
                pkgInfo.signatures ?: emptyArray()
            }
            if (signatures.isEmpty()) return ""
            val md = MessageDigest.getInstance("SHA-1")
            val digest = md.digest(signatures[0].toByteArray())
            digest.joinToString(":") { "%02X".format(it) }
        } catch (_: Exception) {
            ""
        }
    }

    private fun fetchAccessTokenAsync(
        account: GoogleSignInAccount,
        driveScope: String,
        invalidateToken: String?,
        allowInteractiveConsent: Boolean,
        callbackResult: MethodChannel.Result
    ) {
        val androidAccount: Account? = account.account ?: account.email?.let { Account(it, "com.google") }
        if (androidAccount == null) {
            runOnUiThread {
                callbackResult.error("NO_ACCOUNT", "Google account email unavailable.", null)
            }
            return
        }

        Thread {
            try {
                if (!invalidateToken.isNullOrBlank()) {
                    try {
                        GoogleAuthUtil.clearToken(applicationContext, invalidateToken)
                    } catch (_: Exception) {
                    }
                }
                val oauthScope =
                    "oauth2:$driveScope https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
                val token = GoogleAuthUtil.getToken(applicationContext, androidAccount, oauthScope)
                val payload = hashMapOf<String, Any?>(
                    "signedIn" to true,
                    "email" to (account.email ?: ""),
                    "displayName" to (account.displayName ?: account.email ?: "Google Account"),
                    "photoUrl" to (account.photoUrl?.toString() ?: ""),
                    "accessToken" to token,
                    "authMethod" to "native_google_sso"
                )
                runOnUiThread {
                    callbackResult.success(payload)
                }
            } catch (recoverable: UserRecoverableAuthException) {
                val consentIntent = recoverable.intent
                if (allowInteractiveConsent && consentIntent != null) {
                    runOnUiThread {
                        pendingConsentAccount = account
                        pendingSignInResult = callbackResult
                        pendingDriveScope = driveScope
                        startActivityForResult(consentIntent, REQ_GOOGLE_CONSENT)
                    }
                } else {
                    runOnUiThread {
                        callbackResult.success(hashMapOf<String, Any?>("signedIn" to false))
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    callbackResult.error(
                        "TOKEN_ERROR",
                        e.localizedMessage ?: "Failed to obtain Google Drive token",
                        mapOf("packageName" to packageName, "sha1" to computeSigningSha1())
                    )
                }
            }
        }.start()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQ_GOOGLE_SIGN_IN) {
            val res = pendingSignInResult ?: return
            pendingSignInResult = null

            val task = GoogleSignIn.getSignedInAccountFromIntent(data)
            try {
                val account = task.getResult(ApiException::class.java)
                if (account != null) {
                    fetchAccessTokenAsync(
                        account = account,
                        driveScope = pendingDriveScope,
                        invalidateToken = null,
                        allowInteractiveConsent = true,
                        callbackResult = res
                    )
                } else {
                    res.error("SIGN_IN_NULL", "No Google account selected.", null)
                }
            } catch (apiEx: ApiException) {
                val code = apiEx.statusCode
                if (code == 12501 || resultCode == Activity.RESULT_CANCELED) {
                    res.error("SIGN_IN_CANCELED", "Google Sign-In was canceled.", null)
                } else if (code == 10) {
                    res.error(
                        "SIGN_IN_SHA1_NOT_REGISTERED",
                        "Register Android OAuth Client in Google Cloud Console (Package: $packageName, SHA-1: ${computeSigningSha1()}) or enter an OAuth Client ID.",
                        mapOf("packageName" to packageName, "sha1" to computeSigningSha1())
                    )
                } else {
                    res.error(
                        "SIGN_IN_FAILED_$code",
                        "Google Sign-In error ($code): ${apiEx.localizedMessage}",
                        mapOf("packageName" to packageName, "sha1" to computeSigningSha1())
                    )
                }
            }
            return
        }

        if (requestCode == REQ_GOOGLE_CONSENT) {
            val res = pendingSignInResult ?: return
            val account = pendingConsentAccount
            pendingSignInResult = null
            pendingConsentAccount = null

            if (resultCode == Activity.RESULT_OK && account != null) {
                fetchAccessTokenAsync(
                    account = account,
                    driveScope = pendingDriveScope,
                    invalidateToken = null,
                    allowInteractiveConsent = false,
                    callbackResult = res
                )
            } else {
                res.error("CONSENT_DENIED", "Google Drive storage permission was not granted.", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Launcher Widget + Local Store Channel
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLaunchGuestId" -> {
                    val id = pendingLaunchGuestId
                    pendingLaunchGuestId = null
                    pendingScheduledSlot?.let { slot ->
                        pendingScheduledSlot = null
                        channel.invokeMethod("runScheduledDailySearch", slot)
                    }
                    result.success(id)
                }
                "readLocalStore" -> {
                    val file = File(filesDir, STORE_FILENAME)
                    val content = if (file.exists()) file.readText() else ""
                    result.success(content)
                }
                "writeLocalStore" -> {
                    val storeJson = call.argument<String>("storeJson") ?: "{}"
                    File(filesDir, STORE_FILENAME).writeText(storeJson)
                    result.success(true)
                }
                "updateWidgetGuests" -> {
                    val guestsJson = call.argument<String>("guestsJson") ?: "[]"
                    val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    prefs.edit().putString(KEY_RECENT_TEN_JSON, guestsJson).apply()

                    val appWidgetManager = AppWidgetManager.getInstance(this)
                    val component = ComponentName(this, PrestonGuestWidgetProvider::class.java)
                    val appWidgetIds = appWidgetManager.getAppWidgetIds(component)
                    appWidgetManager.notifyAppWidgetViewDataChanged(
                        appWidgetIds,
                        R.id.widget_guest_list
                    )
                    PrestonGuestWidgetProvider.updateAllWidgets(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 2. Native Google Single Sign-On + Drive Token Channel
        val gChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUTH_CHANNEL)
        authChannel = gChannel

        gChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSigningInfo" -> {
                    val redirect = pendingOAuthRedirectUri
                    pendingOAuthRedirectUri = null
                    result.success(
                        hashMapOf(
                            "packageName" to packageName,
                            "sha1" to computeSigningSha1(),
                            "pendingOAuthRedirect" to redirect
                        )
                    )
                }
                "signInWithGoogle" -> {
                    val driveScope = call.argument<String>("driveScope") ?: DEFAULT_DRIVE_SCOPE
                    val webClientId = call.argument<String>("webClientId")
                    pendingDriveScope = driveScope
                    pendingSignInResult = result
                    val client = buildGoogleSignInClient(driveScope, webClientId)
                    startActivityForResult(client.signInIntent, REQ_GOOGLE_SIGN_IN)
                }
                "silentSignIn" -> {
                    val driveScope = call.argument<String>("driveScope") ?: DEFAULT_DRIVE_SCOPE
                    val webClientId = call.argument<String>("webClientId")
                    val invalidateToken = call.argument<String>("invalidateToken")

                    val lastAccount = GoogleSignIn.getLastSignedInAccount(this)
                    if (lastAccount != null) {
                        fetchAccessTokenAsync(
                            account = lastAccount,
                            driveScope = driveScope,
                            invalidateToken = invalidateToken,
                            allowInteractiveConsent = false,
                            callbackResult = result
                        )
                    } else {
                        val client = buildGoogleSignInClient(driveScope, webClientId)
                        client.silentSignIn().addOnCompleteListener { task ->
                            if (task.isSuccessful && task.result != null) {
                                fetchAccessTokenAsync(
                                    account = task.result!!,
                                    driveScope = driveScope,
                                    invalidateToken = invalidateToken,
                                    allowInteractiveConsent = false,
                                    callbackResult = result
                                )
                            } else {
                                result.success(hashMapOf<String, Any?>("signedIn" to false))
                            }
                        }
                    }
                }
                "signOut" -> {
                    val client = buildGoogleSignInClient(DEFAULT_DRIVE_SCOPE, null)
                    client.signOut().addOnCompleteListener {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
