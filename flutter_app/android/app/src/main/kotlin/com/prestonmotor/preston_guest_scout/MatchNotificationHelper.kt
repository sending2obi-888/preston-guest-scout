package com.prestonmotor.preston_guest_scout

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.text.NumberFormat
import java.util.Locale

/**
 * Builds and dispatches full Android heads-up notifications whenever a new matching vehicle
 * is discovered for a guest AFTER their first initial search.
 */
object MatchNotificationHelper {
    const val MATCH_ALERT_CHANNEL_ID = "preston_match_alerts_v2"
    private const val LEGACY_CHANNEL_ID = "preston_match_alerts"
    private const val GROUP_KEY_VEHICLE_MATCHES = "com.prestonmotor.scout.VEHICLE_MATCHES"
    private const val SUMMARY_NOTIFICATION_ID = 770000
    private const val BRAND_COLOR = 0xFF0B57D0.toInt()

    fun ensureChannelCreated(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return

        // Clean up older silent/cached channel if present
        try {
            nm.deleteNotificationChannel(LEGACY_CHANNEL_ID)
        } catch (_: Exception) {
        }

        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val audioAttrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val channel = NotificationChannel(
            MATCH_ALERT_CHANNEL_ID,
            "New Vehicle Match Alerts",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description =
                "Heads-up alerts with guest name and vehicle model whenever a new match is found after the initial search"
            enableVibration(true)
            vibrationPattern = longArrayOf(0L, 280L, 140L, 280L)
            enableLights(true)
            lightColor = BRAND_COLOR
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setShowBadge(true)
            if (soundUri != null) {
                setSound(soundUri, audioAttrs)
            }
        }
        nm.createNotificationChannel(channel)
    }

    fun hasPostNotificationsRuntimePermission(context: Context): Boolean {
        return Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
    }

    fun areNotificationsFullyEnabled(context: Context): Boolean {
        ensureChannelCreated(context)
        if (!hasPostNotificationsRuntimePermission(context)) return false
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            val ch = nm?.getNotificationChannel(MATCH_ALERT_CHANNEL_ID)
            if (ch != null && ch.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        return true
    }

    fun openAppNotificationSettings(context: Context): Boolean {
        return try {
            ensureChannelCreated(context)
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", context.packageName, null)
                }
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun postMatchNotification(
        context: Context,
        notifId: Int,
        guestId: String,
        guestName: String,
        guestPhone: String = "",
        vehicleModel: String = "",
        vehicleTitle: String = "",
        price: Double? = null,
        location: String = "",
        fallbackTitle: String = "",
        fallbackBody: String = ""
    ): Boolean {
        ensureChannelCreated(context)
        if (!hasPostNotificationsRuntimePermission(context)) {
            return false
        }
        val nmCompat = NotificationManagerCompat.from(context)
        if (!nmCompat.areNotificationsEnabled()) {
            return false
        }

        val cleanGuest = guestName.trim().ifEmpty { "Guest" }
        val cleanModel = vehicleModel.trim().ifEmpty {
            vehicleTitle.trim().ifEmpty { "Vehicle" }
        }
        val resolvedTitle = if (fallbackTitle.isNotBlank()) {
            fallbackTitle.trim()
        } else {
            "$cleanGuest - Match Found - $cleanModel"
        }

        val currencyFmt = NumberFormat.getCurrencyInstance(Locale.US).apply {
            maximumFractionDigits = 0
        }
        val priceLabel = if (price != null && price > 0.0) currencyFmt.format(price) else ""
        val cleanLocation = location.trim()

        val metaParts = mutableListOf<String>()
        if (priceLabel.isNotEmpty()) metaParts.add(priceLabel)
        if (cleanLocation.isNotEmpty()) metaParts.add(cleanLocation)

        val collapsedSummary = if (guestName.isNotBlank() && vehicleModel.isNotBlank()) {
            if (metaParts.isNotEmpty()) {
                "New $cleanModel found for $cleanGuest • ${metaParts.joinToString(" • ")}"
            } else {
                "New $cleanModel found for $cleanGuest — tap to view match"
            }
        } else if (fallbackBody.isNotBlank()) {
            fallbackBody.trim()
        } else {
            "$resolvedTitle — tap to view match"
        }

        val expandedLines = mutableListOf<String>()
        expandedLines.add("Guest: $cleanGuest")
        val fullVehicleDesc = if (vehicleTitle.isNotBlank() &&
            !vehicleTitle.equals(cleanModel, ignoreCase = true)
        ) {
            "$cleanModel (${vehicleTitle.trim()})"
        } else {
            cleanModel
        }
        expandedLines.add("Vehicle Found: $fullVehicleDesc")
        if (priceLabel.isNotEmpty()) expandedLines.add("Price: $priceLabel")
        if (cleanLocation.isNotEmpty()) expandedLines.add("Dealership: $cleanLocation")
        expandedLines.add("Tap to open $cleanGuest's matched vehicles.")
        val expandedBody = expandedLines.joinToString("\n")

        val openGuestIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (guestId.isNotBlank()) {
                putExtra(MainActivity.EXTRA_GUEST_ID, guestId)
                data = Uri.parse("prestonscout://guest/$guestId")
            }
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentPendingIntent =
            PendingIntent.getActivity(context, notifId, openGuestIntent, pendingFlags)

        val largeIconBitmap = try {
            BitmapFactory.decodeResource(context.resources, R.mipmap.ic_launcher)
        } catch (_: Exception) {
            null
        }

        val builder = NotificationCompat.Builder(context, MATCH_ALERT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_vehicle_match)
            .setColor(BRAND_COLOR)
            .setContentTitle(resolvedTitle)
            .setContentText(collapsedSummary)
            .setSubText("New Vehicle Match")
            .setTicker(resolvedTitle)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .setBigContentTitle(resolvedTitle)
                    .setSummaryText("$cleanGuest • $cleanModel")
                    .bigText(expandedBody)
            )
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setGroup(GROUP_KEY_VEHICLE_MATCHES)
            .setContentIntent(contentPendingIntent)
            .addAction(
                R.drawable.ic_stat_vehicle_match,
                "View Match",
                contentPendingIntent
            )

        if (largeIconBitmap != null) {
            builder.setLargeIcon(largeIconBitmap)
        }

        val cleanPhone = guestPhone.trim()
        if (cleanPhone.isNotEmpty()) {
            val dialDigits = cleanPhone.filter { it.isDigit() || it == '+' }
            if (dialDigits.isNotEmpty()) {
                val dialIntent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$dialDigits")).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                val dialPendingIntent = PendingIntent.getActivity(
                    context,
                    notifId + 100_000,
                    dialIntent,
                    pendingFlags
                )
                val firstName = cleanGuest.split(" ").firstOrNull()?.ifBlank { "Guest" } ?: "Guest"
                builder.addAction(
                    android.R.drawable.ic_menu_call,
                    "Call $firstName",
                    dialPendingIntent
                )
            }
        }

        return try {
            nmCompat.notify(notifId, builder.build())
            postGroupSummaryIfNeeded(context, nmCompat)
            true
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun postGroupSummaryIfNeeded(
        context: Context,
        nmCompat: NotificationManagerCompat
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        val activeMatchNotifs = try {
            nm.activeNotifications.filter {
                it.id != SUMMARY_NOTIFICATION_ID &&
                    it.notification.group == GROUP_KEY_VEHICLE_MATCHES
            }
        } catch (_: Exception) {
            emptyList()
        }
        if (activeMatchNotifs.size < 2) return

        val launchAppIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val summaryPending = PendingIntent.getActivity(
            context,
            SUMMARY_NOTIFICATION_ID,
            launchAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val inbox = NotificationCompat.InboxStyle()
            .setBigContentTitle("${activeMatchNotifs.size} New Guest Vehicle Matches")
            .setSummaryText("Preston Motor Guest Scout")

        for (sbn in activeMatchNotifs.take(6)) {
            val line = sbn.notification.extras?.getCharSequence(Notification.EXTRA_TITLE)
                ?.toString()
            if (!line.isNullOrBlank()) {
                inbox.addLine(line)
            }
        }

        val summaryNotification = NotificationCompat.Builder(context, MATCH_ALERT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_vehicle_match)
            .setColor(BRAND_COLOR)
            .setContentTitle("${activeMatchNotifs.size} New Guest Vehicle Matches")
            .setContentText("Tap to view matched vehicles for your guests")
            .setStyle(inbox)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setGroup(GROUP_KEY_VEHICLE_MATCHES)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAutoCancel(true)
            .setContentIntent(summaryPending)
            .build()

        try {
            nmCompat.notify(SUMMARY_NOTIFICATION_ID, summaryNotification)
        } catch (_: SecurityException) {
        }
    }
}
