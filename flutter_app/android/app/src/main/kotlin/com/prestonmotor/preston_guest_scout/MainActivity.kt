package com.prestonmotor.preston_guest_scout

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "com.prestonmotor.scout/launcher_widget"
        const val PREFS_NAME = "preston_scout_widget_prefs"
        const val KEY_RECENT_TEN_JSON = "recent_ten_guests_json"
        const val EXTRA_GUEST_ID = "extra_guest_id"
        const val EXTRA_SCHEDULED_SLOT = "extra_scheduled_slot"
        const val STORE_FILENAME = "preston_scout_store.json"
    }

    private var methodChannel: MethodChannel? = null
    private var pendingLaunchGuestId: String? = null
    private var pendingScheduledSlot: String? = null

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }
}
