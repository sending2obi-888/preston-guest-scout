@file:Suppress("DEPRECATION")

package com.prestonmotor.preston_guest_scout

import android.accounts.Account
import android.accounts.AccountManager
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.UserRecoverableAuthException
import com.google.android.gms.auth.api.signin.GoogleSignIn
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
        const val NOTIF_CHANNEL = "com.prestonmotor.scout/notifications"
        const val MATCH_ALERT_CHANNEL_ID = "preston_match_alerts"
        const val PREFS_NAME = "preston_scout_widget_prefs"
        const val KEY_RECENT_TEN_JSON = "recent_ten_guests_json"
        const val KEY_SIGNED_IN_EMAIL = "google_sso_selected_email"
        const val EXTRA_GUEST_ID = "extra_guest_id"
        const val EXTRA_SCHEDULED_SLOT = "extra_scheduled_slot"
        const val STORE_FILENAME = "preston_scout_store.json"

        private const val REQ_GOOGLE_SIGN_IN = 9001
        private const val REQ_GOOGLE_CONSENT = 9002
        private const val REQ_CHOOSE_GOOGLE_ACCOUNT = 9003
        private const val REQ_POST_NOTIFICATIONS = 9004
        private const val DEFAULT_DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
    }

    private var methodChannel: MethodChannel? = null
    private var authChannel: MethodChannel? = null
    private var notifChannel: MethodChannel? = null
    private var pendingLaunchGuestId: String? = null
    private var pendingScheduledSlot: String? = null
    private var pendingOAuthRedirectUri: String? = null

    private var pendingSignInResult: MethodChannel.Result? = null
    private var pendingDriveScope: String = DEFAULT_DRIVE_SCOPE
    private var pendingConsentEmail: String? = null
    private var pendingConsentDisplayName: String? = null
    private var pendingConsentPhotoUrl: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureNotificationChannelCreated()
        requestPostNotificationsPermissionIfNeeded()
        DailySearchAlarmReceiver.scheduleTwiceDailyAlarms(this)
        handleIncomingIntent(intent, isColdStart = true)
    }

    private fun ensureNotificationChannelCreated() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                MATCH_ALERT_CHANNEL_ID,
                "New Vehicle Match Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description =
                    "Alerts when a new matching vehicle is found on prestonmotor.com after a client's initial search"
                enableVibration(true)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun requestPostNotificationsPermissionIfNeeded(): Boolean {
        if (Build.VERSION.SDK_INT >= 33) {
            val perm = "android.permission.POST_NOTIFICATIONS"
            if (checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(perm), REQ_POST_NOTIFICATIONS)
                return false
            }
        }
        return true
    }

    private fun postMatchSystemNotification(
        notifId: Int,
        guestId: String,
        title: String,
        body: String
    ): Boolean {
        ensureNotificationChannelCreated()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return false
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
        ) {
            requestPostNotificationsPermissionIfNeeded()
            return false
        }

        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (guestId.isNotBlank()) {
                putExtra(EXTRA_GUEST_ID, guestId)
                data = Uri.parse("prestonscout://guest/$guestId")
            }
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPendingIntent = PendingIntent.getActivity(this, notifId, tapIntent, pendingFlags)

        val displayBody = if (body.isNotBlank()) body else title
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MATCH_ALERT_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(displayBody)
            .setStyle(
                Notification.BigTextStyle()
                    .setBigContentTitle(title)
                    .bigText(displayBody)
            )
            .setAutoCancel(true)
            .setContentIntent(contentPendingIntent)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_HIGH)
            builder.setDefaults(Notification.DEFAULT_ALL)
        }

        nm.notify(notifId, builder.build())
        return true
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

    private fun buildGoogleSignInClient(driveScope: String): GoogleSignInClient {
        val builder = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestProfile()
            .requestScopes(Scope(driveScope))
        return GoogleSignIn.getClient(this, builder.build())
    }

    private fun saveSelectedEmail(email: String?) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (email.isNullOrBlank()) {
            prefs.edit().remove(KEY_SIGNED_IN_EMAIL).apply()
        } else {
            prefs.edit().putString(KEY_SIGNED_IN_EMAIL, email.trim()).apply()
        }
    }

    private fun readSavedSelectedEmail(): String? {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_SIGNED_IN_EMAIL, null)
        return if (raw.isNullOrBlank()) null else raw.trim()
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

    private fun launchNativeAccountPicker(driveScope: String, callbackResult: MethodChannel.Result) {
        pendingDriveScope = driveScope
        pendingSignInResult = callbackResult
        try {
            val pickerIntent = AccountManager.newChooseAccountIntent(
                null,
                null,
                arrayOf("com.google"),
                null,
                null,
                null,
                null
            )
            startActivityForResult(pickerIntent, REQ_CHOOSE_GOOGLE_ACCOUNT)
        } catch (_: ActivityNotFoundException) {
            val client = buildGoogleSignInClient(driveScope)
            startActivityForResult(client.signInIntent, REQ_GOOGLE_SIGN_IN)
        } catch (e: Exception) {
            pendingSignInResult = null
            callbackResult.error(
                "ACCOUNT_PICKER_ERROR",
                e.localizedMessage ?: "Unable to open Google account chooser.",
                mapOf("packageName" to packageName, "sha1" to computeSigningSha1())
            )
        }
    }

    private fun fetchAccessTokenForEmailAsync(
        email: String,
        displayName: String?,
        photoUrl: String?,
        driveScope: String,
        invalidateToken: String?,
        allowInteractiveConsent: Boolean,
        callbackResult: MethodChannel.Result
    ) {
        val cleanEmail = email.trim()
        if (cleanEmail.isEmpty()) {
            runOnUiThread {
                callbackResult.error("NO_ACCOUNT", "Google account email unavailable.", null)
            }
            return
        }

        val androidAccount = Account(cleanEmail, "com.google")
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
                saveSelectedEmail(cleanEmail)
                val resolvedName = if (!displayName.isNullOrBlank()) displayName else cleanEmail
                val payload = hashMapOf<String, Any?>(
                    "signedIn" to true,
                    "email" to cleanEmail,
                    "displayName" to resolvedName,
                    "photoUrl" to (photoUrl ?: ""),
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
                        pendingConsentEmail = cleanEmail
                        pendingConsentDisplayName = displayName
                        pendingConsentPhotoUrl = photoUrl
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
                // Occurs when (packageName, SHA-1) has not been registered as an Android OAuth 2.0 Client yet.
                // Return structured payload with selectedEmail so Flutter can chain straight into
                // Device Code / PKCE / Server Sync or display the 1-time OAuth setup guide.
                val payload = hashMapOf<String, Any?>(
                    "signedIn" to false,
                    "needsOAuthClientSetup" to true,
                    "selectedEmail" to cleanEmail,
                    "packageName" to packageName,
                    "sha1" to computeSigningSha1(),
                    "nativeAuthError" to (e.localizedMessage ?: e.javaClass.simpleName)
                )
                runOnUiThread {
                    callbackResult.success(payload)
                }
            }
        }.start()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQ_CHOOSE_GOOGLE_ACCOUNT) {
            val res = pendingSignInResult ?: return
            pendingSignInResult = null

            if (resultCode == Activity.RESULT_OK && data != null) {
                val email = data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)?.trim() ?: ""
                if (email.isNotEmpty()) {
                    saveSelectedEmail(email)
                    fetchAccessTokenForEmailAsync(
                        email = email,
                        displayName = null,
                        photoUrl = null,
                        driveScope = pendingDriveScope,
                        invalidateToken = null,
                        allowInteractiveConsent = true,
                        callbackResult = res
                    )
                    return
                }
            }

            res.error(
                "SIGN_IN_CANCELED",
                "Account selection was closed before choosing a Google account.",
                null
            )
            return
        }

        if (requestCode == REQ_GOOGLE_SIGN_IN) {
            val res = pendingSignInResult ?: return
            pendingSignInResult = null

            val task = GoogleSignIn.getSignedInAccountFromIntent(data)
            try {
                val account = task.getResult(ApiException::class.java)
                val email = account?.email?.trim() ?: ""
                if (email.isNotEmpty()) {
                    saveSelectedEmail(email)
                    fetchAccessTokenForEmailAsync(
                        email = email,
                        displayName = account?.displayName,
                        photoUrl = account?.photoUrl?.toString(),
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
                // Always check developer/configuration status codes BEFORE RESULT_CANCELED,
                // because Play Services sets resultCode=RESULT_CANCELED on statusCode=10!
                if (code == 10 || code == 12500) {
                    res.success(
                        hashMapOf<String, Any?>(
                            "signedIn" to false,
                            "needsOAuthClientSetup" to true,
                            "selectedEmail" to (readSavedSelectedEmail() ?: ""),
                            "packageName" to packageName,
                            "sha1" to computeSigningSha1(),
                            "nativeAuthError" to "GoogleSignIn status $code"
                        )
                    )
                } else if (code == 12501) {
                    res.error(
                        "SIGN_IN_CANCELED",
                        "Account selection was closed before choosing a Google account.",
                        null
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
            val email = pendingConsentEmail
            val displayName = pendingConsentDisplayName
            val photoUrl = pendingConsentPhotoUrl
            pendingSignInResult = null
            pendingConsentEmail = null
            pendingConsentDisplayName = null
            pendingConsentPhotoUrl = null

            if (resultCode == Activity.RESULT_OK && !email.isNullOrBlank()) {
                fetchAccessTokenForEmailAsync(
                    email = email,
                    displayName = displayName,
                    photoUrl = photoUrl,
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
                            "pendingOAuthRedirect" to redirect,
                            "savedEmail" to readSavedSelectedEmail()
                        )
                    )
                }
                "signInWithGoogle" -> {
                    val driveScope = call.argument<String>("driveScope") ?: DEFAULT_DRIVE_SCOPE
                    launchNativeAccountPicker(driveScope, result)
                }
                "silentSignIn" -> {
                    val driveScope = call.argument<String>("driveScope") ?: DEFAULT_DRIVE_SCOPE
                    val invalidateToken = call.argument<String>("invalidateToken")

                    val savedEmail = readSavedSelectedEmail()
                    val lastAccount = GoogleSignIn.getLastSignedInAccount(this)
                    val targetEmail = savedEmail ?: lastAccount?.email?.trim()

                    if (!targetEmail.isNullOrBlank()) {
                        fetchAccessTokenForEmailAsync(
                            email = targetEmail,
                            displayName = lastAccount?.displayName,
                            photoUrl = lastAccount?.photoUrl?.toString(),
                            driveScope = driveScope,
                            invalidateToken = invalidateToken,
                            allowInteractiveConsent = false,
                            callbackResult = result
                        )
                    } else {
                        val client = buildGoogleSignInClient(driveScope)
                        client.silentSignIn().addOnCompleteListener { task ->
                            if (task.isSuccessful && task.result?.email != null) {
                                val acct = task.result!!
                                fetchAccessTokenForEmailAsync(
                                    email = acct.email!!,
                                    displayName = acct.displayName,
                                    photoUrl = acct.photoUrl?.toString(),
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
                    saveSelectedEmail(null)
                    val client = buildGoogleSignInClient(DEFAULT_DRIVE_SCOPE)
                    client.signOut().addOnCompleteListener {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 3. Post-Initial-Search Match System Notification Channel
        val nChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIF_CHANNEL)
        nChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    val granted = requestPostNotificationsPermissionIfNeeded()
                    result.success(granted)
                }
                "areNotificationsEnabled" -> {
                    val granted = Build.VERSION.SDK_INT < 33 ||
                        checkSelfPermission("android.permission.POST_NOTIFICATIONS") ==
                            PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }
                "showMatchNotification" -> {
                    val notifId = call.argument<Int>("notifId")
                        ?: (System.currentTimeMillis() % 1000000L).toInt()
                    val guestId = call.argument<String>("guestId") ?: ""
                    val title = call.argument<String>("title") ?: "Match Found"
                    val body = call.argument<String>("body") ?: ""
                    val ok = postMatchSystemNotification(
                        notifId = notifId,
                        guestId = guestId,
                        title = title,
                        body = body
                    )
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
    }
}

