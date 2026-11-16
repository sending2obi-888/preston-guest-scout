package com.prestonmotor.preston_guest_scout

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Automatically boots Preston Guest Scout at startup on the Googlebook (Chromebook ARCVM) / Android
 * and registers the twice-daily 7:30 AM & 2:00 PM alarms.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (
            action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            DailySearchAlarmReceiver.scheduleTwiceDailyAlarms(context)
            PrestonGuestWidgetProvider.updateAllWidgets(context)
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            context.startActivity(launchIntent)
        }
    }
}
