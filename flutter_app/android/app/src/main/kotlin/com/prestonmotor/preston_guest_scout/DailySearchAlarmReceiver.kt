package com.prestonmotor.preston_guest_scout

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.util.Calendar

/**
 * Schedules and handles twice-daily (7:30 AM and 2:00 PM) Gemini Agent searches on Googlebook / Android.
 */
class DailySearchAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val slotLabel = intent.getStringExtra("slot_label") ?: "Scheduled Daily Search"

        // Re-arm next day's 7:30 AM & 2:00 PM alarms
        scheduleTwiceDailyAlarms(context)

        // Launch/notify MainActivity to execute the prestonmotor.com Gemini scan & update Widget
        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(MainActivity.EXTRA_SCHEDULED_SLOT, slotLabel)
        }
        context.startActivity(launch)
    }

    companion object {
        private const val REQ_MORNING_730 = 730
        private const val REQ_AFTERNOON_1400 = 1400

        fun scheduleTwiceDailyAlarms(context: Context) {
            scheduleDailySlot(context, 7, 30, REQ_MORNING_730, "7:30 AM Daily Search")
            scheduleDailySlot(context, 14, 0, REQ_AFTERNOON_1400, "2:00 PM Daily Search")
        }

        private fun scheduleDailySlot(
            context: Context,
            hourOfDay: Int,
            minute: Int,
            requestCode: Int,
            slotLabel: String
        ) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return

            val target = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, hourOfDay)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                if (timeInMillis <= System.currentTimeMillis()) {
                    add(Calendar.DAY_OF_YEAR, 1)
                }
            }

            val intent = Intent(context, DailySearchAlarmReceiver::class.java).apply {
                putExtra("slot_label", slotLabel)
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            alarmManager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                target.timeInMillis,
                pendingIntent
            )
        }
    }
}
