package com.prestonmotor.preston_guest_scout

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Automatically arms twice-daily 7:30 AM & 2:00 PM alarms + periodic background JobScheduler
 * scans on Android & Googlebook startup so post-initial-search vehicle match notifications work
 * reliably after device reboot.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (
            action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            MatchNotificationHelper.ensureChannelCreated(context)
            DailySearchAlarmReceiver.scheduleTwiceDailyAlarms(context)
            BackgroundMatchScanJobService.schedulePeriodicBackgroundScan(context)
            PrestonGuestWidgetProvider.updateAllWidgets(context)
            try {
                val launchIntent = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
                context.startActivity(launchIntent)
            } catch (_: Exception) {
                // Expected on Android 10+ phones where background activity launches on boot are restricted;
                // alarms and JobScheduler background scans remain armed.
            }
        }
    }
}
