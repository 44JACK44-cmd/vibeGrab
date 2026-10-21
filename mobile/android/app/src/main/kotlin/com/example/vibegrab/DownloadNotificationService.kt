package com.example.vibegrab

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

class DownloadNotificationService : Service() {
    companion object {
        const val CHANNEL_PROGRESS = "vibegrab_downloading"
        const val CHANNEL_RESULTS = "vibegrab_results"
        const val FOREGROUND_ID = 9001

        /// Terminal notifications must not stay forever in the shade. Ten
        /// seconds is the minimum the product accepts; callers may ask for
        /// more, never less. The native `setTimeoutAfter` handles API 26+ and
        /// the Handler below covers the older devices (minSdk 24).
        const val MIN_RESULT_TIMEOUT_MS = 10_000L

        fun applyResultsSound(context: Context, enabled: Boolean) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.deleteNotificationChannel(CHANNEL_RESULTS)
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_RESULTS, "Download Results",
                if (enabled) NotificationManager.IMPORTANCE_DEFAULT
                else NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Download complete or failed notifications" })
        }
    }

    private val activeTasks = mutableSetOf<String>()
    private var isForeground = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private val resultDismissals = mutableMapOf<Int, Runnable>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onDestroy() {
        resultDismissals.values.forEach(mainHandler::removeCallbacks)
        resultDismissals.clear()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val command = intent?.getStringExtra("command") ?: return START_NOT_STICKY

        if (!isForeground && command != "removeTask" && command != "stop") {
            ensureForeground()
        }

        when (command) {
            "start" -> { /* foreground already ensured */ }
            "update" -> updateProgress(
                intent.getStringExtra("taskId") ?: return START_NOT_STICKY,
                intent.getStringExtra("title") ?: "Downloading...",
                intent.getDoubleExtra("progress", 0.0),
                intent.getLongExtra("speedBps", 0L),
            )
            "completed" -> showCompleted(
                intent.getStringExtra("taskId") ?: return START_NOT_STICKY,
                intent.getStringExtra("title") ?: "Download",
                resultTimeout(intent),
            )
            "failed" -> showFailed(
                intent.getStringExtra("taskId") ?: return START_NOT_STICKY,
                intent.getStringExtra("title") ?: "Download",
                resultTimeout(intent),
            )
            "removeTask" -> {
                val taskId = intent.getStringExtra("taskId")
                activeTasks.remove(taskId)
                if (taskId != null) dismissResults(taskId)
                if (activeTasks.isEmpty()) stopClean()
            }
            "stop" -> stopClean()
        }
        return START_STICKY
    }

    private fun ensureForeground() {
        val notification = baseBuilder()
            .setContentText("Preparing download...")
            .setProgress(0, 0, true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceCompat.startForeground(this, FOREGROUND_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            @Suppress("DEPRECATION")
            startForeground(FOREGROUND_ID, notification)
        }
        isForeground = true
    }

    private fun createNotificationChannels() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_PROGRESS, "Download Progress",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Shows download progress"; setShowBadge(false) })
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_RESULTS, "Download Results",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { description = "Download complete or failed notifications" })
        }
    }

    private fun baseBuilder(): NotificationCompat.Builder =
        NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("VibeGrab")
            .setOngoing(true)
            .setOnlyAlertOnce(true)

    private fun updateProgress(
        taskId: String,
        title: String,
        progress: Double,
        speedBps: Long
    ) {
        activeTasks.add(taskId)
        val percentage = (progress * 100).toInt().coerceIn(0, 100)
        val cancelPI = makeActionPI(taskId, "cancel", 10000)
        val text = if (speedBps > 0) {
            "$percentage%  ·  ${formatSpeed(speedBps)}"
        } else {
            "$percentage%"
        }
        val notification = baseBuilder()
            .setContentTitle(title)
            .setContentText(text)
            .setProgress(100, percentage, false)
            .setContentIntent(makeActionPI(taskId, "open", 20000))
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancelPI)
            .build()
        val nm = getSystemService(NotificationManager::class.java) ?: return
        // One card per task: with the shared ID the second download replaced
        // the first one and the user lost track of it.
        nm.notify(progressId(taskId), notification)
        // The foreground notification stays as the summary of the service.
        val summary = baseBuilder()
            .setContentTitle("VibeGrab")
            .setContentText(
                if (activeTasks.size > 1) {
                    "Downloading (${activeTasks.size})"
                } else {
                    title
                }
            )
            .setProgress(100, percentage, activeTasks.size > 1)
            .build()
        nm.notify(FOREGROUND_ID, summary)
    }

    private fun progressId(taskId: String) =
        11000 + (taskId.hashCode().and(0x7FFFFFFF) % 4000)

    private fun formatSpeed(bytesPerSecond: Long): String {
        if (bytesPerSecond >= 1024L * 1024L) {
            return String.format("%.1f MB/s", bytesPerSecond / 1024.0 / 1024.0)
        }
        return String.format("%d KB/s", bytesPerSecond / 1024)
    }

    private fun resultTimeout(intent: Intent): Long =
        intent.getLongExtra("timeoutMs", MIN_RESULT_TIMEOUT_MS)
            .coerceAtLeast(MIN_RESULT_TIMEOUT_MS)

    private fun completedId(taskId: String) =
        2000 + (taskId.hashCode().and(0x7FFFFFFF) % 8000)

    private fun failedId(taskId: String) =
        3000 + (taskId.hashCode().and(0x7FFFFFFF) % 8000)

    /// Cancels the scheduled/finished notification for a removed task. Called
    /// when the user deletes the row in the app: keeping a "completed" card in
    /// the shade for a task that no longer exists is confusing.
    private fun dismissResults(taskId: String) {
        val nm = getSystemService(NotificationManager::class.java)
        val ids = listOf(completedId(taskId), failedId(taskId), progressId(taskId))
        for (id in ids) {
            resultDismissals.remove(id)?.let(mainHandler::removeCallbacks)
            nm?.cancel(id)
        }
    }

    /**
     * Schedules the terminal notification to disappear. API 26+ lets the
     * system do it even if the process dies; on API 24-25 a Handler is the
     * only available fallback. Replacing the same notification cancels the
     * previous runnable first, so a task can never keep an old timer.
     */
    private fun scheduleResultDismissal(notificationId: Int, timeoutMs: Long) {
        resultDismissals.remove(notificationId)?.let(mainHandler::removeCallbacks)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val runnable = Runnable {
            resultDismissals.remove(notificationId)
            nm.cancel(notificationId)
            // API 24-25 keeps the service alive only to run these timers.
            if (resultDismissals.isEmpty() && !isForeground) stopSelf()
        }
        resultDismissals[notificationId] = runnable
        mainHandler.postDelayed(runnable, timeoutMs)
    }

    private fun showCompleted(taskId: String, title: String, timeoutMs: Long) {
        activeTasks.remove(taskId)
        val openPI = makeActionPI(taskId, "open", 20000)
        val builder = NotificationCompat.Builder(this, CHANNEL_RESULTS)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Download complete")
            .setContentText(title)
            .setAutoCancel(true)
            .addAction(android.R.drawable.ic_menu_send, "Open", openPI)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(timeoutMs)
        }
        val nid = completedId(taskId)
        val nm = getSystemService(NotificationManager::class.java)
        // The progress card of this task is replaced by the result card.
        nm?.cancel(progressId(taskId))
        nm?.notify(nid, builder.build())
        scheduleResultDismissal(nid, timeoutMs)
        if (activeTasks.isEmpty()) stopClean()
    }

    private fun showFailed(taskId: String, title: String, timeoutMs: Long) {
        activeTasks.remove(taskId)
        val retryPI = makeActionPI(taskId, "retry", 30000)
        val builder = NotificationCompat.Builder(this, CHANNEL_RESULTS)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("Download failed")
            .setContentText(title)
            .setAutoCancel(true)
            .addAction(android.R.drawable.ic_menu_rotate, "Retry", retryPI)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(timeoutMs)
        }
        val nid = failedId(taskId)
        val nm = getSystemService(NotificationManager::class.java)
        nm?.cancel(progressId(taskId))
        nm?.notify(nid, builder.build())
        scheduleResultDismissal(nid, timeoutMs)
        if (activeTasks.isEmpty()) stopClean()
    }

    private fun makeActionPI(taskId: String, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            this.action = "NOTIFICATION_ACTION"
            putExtra("action", action)
            putExtra("taskId", taskId)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(this, requestCode + taskId.hashCode().and(0x7FFFFFFF),
            intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun stopClean() {
        isForeground = false
        // No task may keep a progress card once the service is gone.
        val nm = getSystemService(NotificationManager::class.java)
        for (taskId in activeTasks) {
            nm?.cancel(progressId(taskId))
        }
        activeTasks.clear()
        stopForeground(STOP_FOREGROUND_REMOVE)
        // On API 24-25 the terminal notifications disappear through the
        // Handler above. Destroying the service now would cancel those
        // callbacks and leave the cards in the shade forever.
        if (resultDismissals.isEmpty()) stopSelf()
    }
}
