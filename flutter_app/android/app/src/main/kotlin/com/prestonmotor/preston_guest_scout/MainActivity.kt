@file:Suppress("DEPRECATION")

package com.prestonmotor.preston_guest_scout

import android.Manifest
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
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.CalendarContract
import android.provider.OpenableColumns
import android.util.Base64
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.UserRecoverableAuthException
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.Calendar
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "com.prestonmotor.scout/launcher_widget"
        const val AUTH_CHANNEL = "com.prestonmotor.scout/google_auth"
        const val NOTIF_CHANNEL = "com.prestonmotor.scout/notifications"
        const val CALENDAR_CHANNEL = "com.prestonmotor.scout/calendar"
        const val MATCH_ALERT_CHANNEL_ID = MatchNotificationHelper.MATCH_ALERT_CHANNEL_ID
        const val PREFS_NAME = "preston_scout_widget_prefs"
        const val KEY_RECENT_TEN_JSON = "recent_ten_guests_json"
        const val KEY_SIGNED_IN_EMAIL = "google_sso_selected_email"
        const val EXTRA_GUEST_ID = "extra_guest_id"
        const val EXTRA_SCHEDULED_SLOT = "extra_scheduled_slot"
        const val STORE_FILENAME = "preston_scout_store.json"

        private const val REQ_GOOGLE_SIGN_IN = 9001
        private const val REQ_GOOGLE_CONSENT = 9002
        private const val REQ_CHOOSE_GOOGLE_ACCOUNT = 9003
        private const val REQ_RUNTIME_PERMISSIONS = 9004
        private const val REQ_CALENDAR_PERMISSIONS = 9005
        private const val REQ_NOTIFICATION_PERMISSIONS = 9006
        private const val REQ_PICK_DOCUMENT = 9007
        private const val MAX_DOCUMENT_BYTES = 18 * 1024 * 1024
        private const val DEFAULT_DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
        private const val DEFAULT_CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.events"

        @Volatile
        private var activeForegroundInstance: MainActivity? = null

        fun dispatchForegroundScheduledSearch(slotLabel: String): Boolean {
            val inst = activeForegroundInstance ?: return false
            val ch = inst.methodChannel ?: return false
            inst.runOnUiThread {
                ch.invokeMethod("runScheduledDailySearch", slotLabel)
            }
            return true
        }
    }

    private var methodChannel: MethodChannel? = null
    private var authChannel: MethodChannel? = null
    private var notifChannel: MethodChannel? = null
    private var calendarChannel: MethodChannel? = null
    private var pendingLaunchGuestId: String? = null
    private var pendingScheduledSlot: String? = null
    private var pendingOAuthRedirectUri: String? = null

    private var pendingSignInResult: MethodChannel.Result? = null
    private var pendingCalendarPermResult: MethodChannel.Result? = null
    private var pendingNotifPermResult: MethodChannel.Result? = null
    private var pendingDocPickerResult: MethodChannel.Result? = null
    private var pendingDriveScope: String = DEFAULT_DRIVE_SCOPE
    private var pendingConsentEmail: String? = null
    private var pendingConsentDisplayName: String? = null
    private var pendingConsentPhotoUrl: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MatchNotificationHelper.ensureChannelCreated(this)
        requestStartupRuntimePermissions()
        DailySearchAlarmReceiver.scheduleTwiceDailyAlarms(this)
        BackgroundMatchScanJobService.schedulePeriodicBackgroundScan(this)
        handleIncomingIntent(intent, isColdStart = true)
    }

    override fun onResume() {
        super.onResume()
        activeForegroundInstance = this
        notifChannel?.invokeMethod(
            "onNotificationPermissionChanged",
            MatchNotificationHelper.areNotificationsFullyEnabled(this)
        )
    }

    override fun onPause() {
        if (activeForegroundInstance === this) {
            activeForegroundInstance = null
        }
        super.onPause()
    }

    private fun requestStartupRuntimePermissions() {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33) {
            val notifPerm = Manifest.permission.POST_NOTIFICATIONS
            if (checkSelfPermission(notifPerm) != PackageManager.PERMISSION_GRANTED) {
                missing.add(notifPerm)
            }
        }
        if (checkSelfPermission(Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.READ_CALENDAR)
        }
        if (checkSelfPermission(Manifest.permission.WRITE_CALENDAR) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.WRITE_CALENDAR)
        }
        if (missing.isNotEmpty()) {
            requestPermissions(missing.toTypedArray(), REQ_RUNTIME_PERMISSIONS)
        }
    }

    private fun requestNotificationPermissionInteractive(callbackResult: MethodChannel.Result) {
        MatchNotificationHelper.ensureChannelCreated(this)
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            callbackResult.success(MatchNotificationHelper.areNotificationsFullyEnabled(this))
            return
        }
        pendingNotifPermResult?.success(MatchNotificationHelper.areNotificationsFullyEnabled(this))
        pendingNotifPermResult = callbackResult
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIFICATION_PERMISSIONS
        )
    }

    private fun hasCalendarPermissions(): Boolean {
        return checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestCalendarPermissionsInteractive(callbackResult: MethodChannel.Result) {
        if (hasCalendarPermissions()) {
            callbackResult.success(true)
            return
        }
        pendingCalendarPermResult?.success(hasCalendarPermissions())
        pendingCalendarPermResult = callbackResult
        requestPermissions(
            arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
            REQ_CALENDAR_PERMISSIONS
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val calGranted = hasCalendarPermissions()
        val notifGranted = MatchNotificationHelper.areNotificationsFullyEnabled(this)

        if (requestCode == REQ_CALENDAR_PERMISSIONS || requestCode == REQ_RUNTIME_PERMISSIONS) {
            calendarChannel?.invokeMethod("onCalendarPermissionChanged", calGranted)
        }
        if (requestCode == REQ_NOTIFICATION_PERMISSIONS || requestCode == REQ_RUNTIME_PERMISSIONS) {
            notifChannel?.invokeMethod("onNotificationPermissionChanged", notifGranted)
        }
        if (requestCode == REQ_CALENDAR_PERMISSIONS) {
            val cb = pendingCalendarPermResult
            pendingCalendarPermResult = null
            cb?.success(calGranted)
        }
        if (requestCode == REQ_NOTIFICATION_PERMISSIONS) {
            val cb = pendingNotifPermResult
            pendingNotifPermResult = null
            cb?.success(notifGranted)
        }
    }

    private fun findWritablePrimaryCalendarId(): Long? {
        if (!hasCalendarPermissions()) return null
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.VISIBLE,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL
        )
        val selection =
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ? AND ${CalendarContract.Calendars.VISIBLE} = 1"
        val selectionArgs = arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString())
        val sortOrder = "${CalendarContract.Calendars.IS_PRIMARY} DESC, ${CalendarContract.Calendars._ID} ASC"

        try {
            contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                sortOrder
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    return cursor.getLong(0)
                }
            }
            contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ?",
                selectionArgs,
                sortOrder
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    return cursor.getLong(0)
                }
            }
        } catch (_: Exception) {
        }
        return null
    }

    private fun adjustSameDaySlotForConflicts(
        calendarId: Long,
        desiredStartMs: Long,
        desiredEndMs: Long,
        timeZoneId: String
    ): Pair<Long, Long> {
        val durationMs = (desiredEndMs - desiredStartMs).coerceAtLeast(10 * 60_000L)
        val tz = try {
            TimeZone.getTimeZone(timeZoneId)
        } catch (_: Exception) {
            TimeZone.getDefault()
        }
        val dayStartCal = Calendar.getInstance(tz).apply {
            timeInMillis = desiredStartMs
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val dayEndCal = Calendar.getInstance(tz).apply {
            timeInMillis = desiredStartMs
            set(Calendar.HOUR_OF_DAY, 23)
            set(Calendar.MINUTE, 58)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val maxEndMs = dayEndCal.timeInMillis

        val busy = mutableListOf<Pair<Long, Long>>()
        try {
            val builder = CalendarContract.Instances.CONTENT_URI.buildUpon()
            ContentUris.appendId(builder, dayStartCal.timeInMillis)
            ContentUris.appendId(builder, maxEndMs)
            contentResolver.query(
                builder.build(),
                arrayOf(
                    CalendarContract.Instances.BEGIN,
                    CalendarContract.Instances.END,
                    CalendarContract.Instances.CALENDAR_ID
                ),
                "${CalendarContract.Instances.CALENDAR_ID} = ?",
                arrayOf(calendarId.toString()),
                "${CalendarContract.Instances.BEGIN} ASC"
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val b = cursor.getLong(0)
                    val e = cursor.getLong(1)
                    if (e > b) busy.add(Pair(b, e))
                }
            }
        } catch (_: Exception) {
            return Pair(desiredStartMs, desiredEndMs.coerceAtMost(maxEndMs))
        }

        if (busy.isEmpty()) {
            return Pair(desiredStartMs, desiredEndMs.coerceAtMost(maxEndMs))
        }

        var candidateStart = desiredStartMs
        val stepMs = 15 * 60_000L
        while (candidateStart + durationMs <= maxEndMs) {
            val candidateEnd = candidateStart + durationMs
            val overlaps = busy.any { (b, e) -> candidateStart < e && candidateEnd > b }
            if (!overlaps) {
                return Pair(candidateStart, candidateEnd)
            }
            candidateStart += stepMs
        }

        return Pair(desiredStartMs, desiredEndMs.coerceAtMost(maxEndMs))
    }

    private fun insertSameDayCallEvent(
        title: String,
        description: String,
        location: String,
        startEpochMs: Long,
        endEpochMs: Long,
        timeZoneId: String
    ): HashMap<String, Any?> {
        if (!hasCalendarPermissions()) {
            return hashMapOf(
                "created" to false,
                "reason" to "CALENDAR_PERMISSION_DENIED"
            )
        }
        val calId = findWritablePrimaryCalendarId()
            ?: return hashMapOf(
                "created" to false,
                "reason" to "NO_WRITABLE_CALENDAR"
            )

        val resolvedTz = if (timeZoneId.isNotBlank()) timeZoneId else TimeZone.getDefault().id
        val (adjStartMs, adjEndMs) = adjustSameDaySlotForConflicts(
            calendarId = calId,
            desiredStartMs = startEpochMs,
            desiredEndMs = endEpochMs,
            timeZoneId = resolvedTz
        )

        return try {
            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calId)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, description)
                put(CalendarContract.Events.EVENT_LOCATION, location)
                put(CalendarContract.Events.DTSTART, adjStartMs)
                put(CalendarContract.Events.DTEND, adjEndMs)
                put(CalendarContract.Events.EVENT_TIMEZONE, resolvedTz)
                put(CalendarContract.Events.HAS_ALARM, 1)
                put(
                    CalendarContract.Events.AVAILABILITY,
                    CalendarContract.Events.AVAILABILITY_BUSY
                )
            }
            val eventUri = contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
            val eventId = eventUri?.lastPathSegment?.toLongOrNull()
            if (eventId != null) {
                try {
                    val reminderValues = ContentValues().apply {
                        put(CalendarContract.Reminders.EVENT_ID, eventId)
                        put(CalendarContract.Reminders.MINUTES, 15)
                        put(
                            CalendarContract.Reminders.METHOD,
                            CalendarContract.Reminders.METHOD_ALERT
                        )
                    }
                    contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, reminderValues)
                } catch (_: Exception) {
                }
                hashMapOf(
                    "created" to true,
                    "eventId" to eventId.toString(),
                    "startEpochMs" to adjStartMs,
                    "endEpochMs" to adjEndMs,
                    "provider" to "android_calendar_provider"
                )
            } else {
                hashMapOf(
                    "created" to false,
                    "reason" to "INSERT_RETURNED_NULL"
                )
            }
        } catch (e: Exception) {
            hashMapOf(
                "created" to false,
                "reason" to (e.localizedMessage ?: "INSERT_EXCEPTION")
            )
        }
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
            .requestScopes(Scope(driveScope), Scope(DEFAULT_CALENDAR_SCOPE))
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
                    "oauth2:$driveScope $DEFAULT_CALENDAR_SCOPE https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
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
            return
        }

        if (requestCode == REQ_PICK_DOCUMENT) {
            val cb = pendingDocPickerResult ?: return
            pendingDocPickerResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                cb.success(hashMapOf<String, Any?>("picked" to false))
                return
            }

            Thread {
                try {
                    var fileName = "uploaded-document"
                    var declaredSize = -1L
                    contentResolver.query(
                        uri,
                        arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                        null,
                        null,
                        null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (nameIdx >= 0 && !cursor.isNull(nameIdx)) {
                                val n = cursor.getString(nameIdx)?.trim()
                                if (!n.isNullOrEmpty()) fileName = n
                            }
                            val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                                declaredSize = cursor.getLong(sizeIdx)
                            }
                        }
                    }

                    if (declaredSize > MAX_DOCUMENT_BYTES) {
                        runOnUiThread {
                            cb.error(
                                "FILE_TOO_LARGE",
                                "Document exceeds 18 MB limit. Please upload a smaller PDF, image, or text document.",
                                null
                            )
                        }
                        return@Thread
                    }

                    val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
                    val out = ByteArrayOutputStream()
                    contentResolver.openInputStream(uri)?.use { input ->
                        val buffer = ByteArray(16 * 1024)
                        var total = 0
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            total += read
                            if (total > MAX_DOCUMENT_BYTES) {
                                runOnUiThread {
                                    cb.error(
                                        "FILE_TOO_LARGE",
                                        "Document exceeds 18 MB limit. Please upload a smaller PDF, image, or text document.",
                                        null
                                    )
                                }
                                return@Thread
                            }
                            out.write(buffer, 0, read)
                        }
                    }

                    val bytes = out.toByteArray()
                    val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                    val payload = hashMapOf<String, Any?>(
                        "picked" to true,
                        "fileName" to fileName,
                        "mimeType" to mimeType,
                        "sizeBytes" to bytes.size,
                        "base64Data" to b64
                    )
                    runOnUiThread {
                        cb.success(payload)
                    }
                } catch (e: Exception) {
                    runOnUiThread {
                        cb.error(
                            "DOCUMENT_READ_ERROR",
                            e.localizedMessage ?: "Unable to read the selected document.",
                            null
                        )
                    }
                }
            }.start()
            return
        }
    }

    private fun launchNativeDocumentPicker(callbackResult: MethodChannel.Result) {
        pendingDocPickerResult?.success(hashMapOf<String, Any?>("picked" to false))
        pendingDocPickerResult = callbackResult
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf(
                        "application/pdf",
                        "image/*",
                        "text/*",
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                        "application/msword",
                        "application/json"
                    )
                )
            }
            startActivityForResult(intent, REQ_PICK_DOCUMENT)
        } catch (e: Exception) {
            pendingDocPickerResult = null
            callbackResult.error(
                "DOCUMENT_PICKER_ERROR",
                e.localizedMessage ?: "Unable to open system document picker.",
                null
            )
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
                "pickDocumentFile" -> {
                    launchNativeDocumentPicker(result)
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
        notifChannel = nChannel
        nChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    requestNotificationPermissionInteractive(result)
                }
                "areNotificationsEnabled" -> {
                    result.success(MatchNotificationHelper.areNotificationsFullyEnabled(this))
                }
                "openNotificationSettings" -> {
                    result.success(MatchNotificationHelper.openAppNotificationSettings(this))
                }
                "showMatchNotification" -> {
                    val notifId = call.argument<Int>("notifId")
                        ?: (System.currentTimeMillis() % 1000000L).toInt()
                    val guestId = call.argument<String>("guestId") ?: ""
                    val guestName = call.argument<String>("guestName") ?: ""
                    val guestPhone = call.argument<String>("guestPhone") ?: ""
                    val vehicleModel = call.argument<String>("vehicleModel") ?: ""
                    val vehicleTitle = call.argument<String>("vehicleTitle") ?: ""
                    val price = call.argument<Number>("price")?.toDouble()
                    val location = call.argument<String>("location") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    val ok = MatchNotificationHelper.postMatchNotification(
                        context = this,
                        notifId = notifId,
                        guestId = guestId,
                        guestName = guestName,
                        guestPhone = guestPhone,
                        vehicleModel = vehicleModel,
                        vehicleTitle = vehicleTitle,
                        price = price,
                        location = location,
                        fallbackTitle = title,
                        fallbackBody = body
                    )
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }

        // 4. Calendar Permissions & Same-Day "Call Guest" Event Channel
        val cChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALENDAR_CHANNEL)
        calendarChannel = cChannel
        cChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestCalendarPermission" -> {
                    requestCalendarPermissionsInteractive(result)
                }
                "hasCalendarPermission" -> {
                    result.success(hasCalendarPermissions())
                }
                "createSameDayCallEvent" -> {
                    val title = call.argument<String>("title") ?: "Call Guest — Vehicle Match Found"
                    val description = call.argument<String>("description") ?: ""
                    val location = call.argument<String>("location") ?: "Preston Automotive Group"
                    val nowMs = System.currentTimeMillis()
                    val startEpochMs = call.argument<Number>("startEpochMs")?.toLong()
                        ?: (nowMs + 30 * 60_000L)
                    val endEpochMs = call.argument<Number>("endEpochMs")?.toLong()
                        ?: (startEpochMs + 30 * 60_000L)
                    val timeZoneId = call.argument<String>("timeZone") ?: TimeZone.getDefault().id
                    val resMap = insertSameDayCallEvent(
                        title = title,
                        description = description,
                        location = location,
                        startEpochMs = startEpochMs,
                        endEpochMs = endEpochMs,
                        timeZoneId = timeZoneId
                    )
                    result.success(resMap)
                }
                else -> result.notImplemented()
            }
        }
    }
}

