package com.prestonmotor.preston_guest_scout

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.PersistableBundle
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android JobScheduler service that executes post-initial-search vehicle scans in the
 * background (surviving reboots and Android 10–15 Background Activity Launch restrictions)
 * and posts full Android heads-up notifications when new matches arrive.
 */
class BackgroundMatchScanJobService : JobService() {
    private val cancelled = AtomicBoolean(false)
    private var workerThread: Thread? = null

    override fun onStartJob(params: JobParameters?): Boolean {
        cancelled.set(false)
        val slotLabel = params?.extras?.getString(KEY_SLOT_LABEL) ?: "Background Inventory Scan"

        // If MainActivity is currently open in the foreground, let the live Flutter engine run the scan
        if (MainActivity.dispatchForegroundScheduledSearch(slotLabel)) {
            jobFinished(params, false)
            return false
        }

        val appCtx = applicationContext
        workerThread = Thread {
            try {
                if (!cancelled.get()) {
                    NativeBackgroundMatchScanner.runBackgroundScan(appCtx, slotLabel)
                }
            } finally {
                jobFinished(params, false)
            }
        }.also { it.start() }

        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        cancelled.set(true)
        workerThread?.interrupt()
        return true
    }

    companion object {
        private const val JOB_ID_PERIODIC_SCAN = 40730
        private const val JOB_ID_IMMEDIATE_ALARM_SCAN = 41400
        private const val KEY_SLOT_LABEL = "slot_label"

        fun schedulePeriodicBackgroundScan(context: Context) {
            val scheduler =
                context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
            val existing = scheduler.allPendingJobs.any { it.id == JOB_ID_PERIODIC_SCAN }
            if (existing) return

            val component = ComponentName(context, BackgroundMatchScanJobService::class.java)
            val extras = PersistableBundle().apply {
                putString(KEY_SLOT_LABEL, "Periodic Android Background Scan")
            }
            // Check inventory periodically in background with network connectivity & persist across reboot
            val jobInfo = JobInfo.Builder(JOB_ID_PERIODIC_SCAN, component)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPersisted(true)
                .setPeriodic(3 * 60 * 60 * 1000L) // every 3 hours
                .setExtras(extras)
                .build()

            try {
                scheduler.schedule(jobInfo)
            } catch (_: Exception) {
            }
        }

        fun enqueueImmediateAlarmScan(context: Context, slotLabel: String) {
            val scheduler =
                context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
            val component = ComponentName(context, BackgroundMatchScanJobService::class.java)
            val extras = PersistableBundle().apply {
                putString(KEY_SLOT_LABEL, slotLabel)
            }
            val jobInfo = JobInfo.Builder(JOB_ID_IMMEDIATE_ALARM_SCAN, component)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setOverrideDeadline(60_000L)
                .setExtras(extras)
                .build()

            try {
                scheduler.schedule(jobInfo)
            } catch (_: Exception) {
            }
        }
    }
}
