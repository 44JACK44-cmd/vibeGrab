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
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

class DownloadNotificationService : Service() {
    companion object {
        const val CHANNEL_PROGRESS = "vibegrab_downloading"
        const val CHANNEL_RESULTS = "vibegrab_results"
        const val FOREGROUND_ID = 9001

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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val command = intent?.getStringExtra("command") ?: return START_NOT_STICKY

        if (!isForeground) {
            ensureForeground()
        }

        when (command) {
            "start" -> { /* foreground already ensured */ }
            "update" -> updateProgress(
                intent.getStringExtra("taskId") ?: return START_NOT_STICKY,
                intent.getStringExtra("title") ?: "Downloading...",
                intent.getDoubleExtra("progress", 0.0),
            )
            "completed" -> showCompleted(
                intent.getStringExtra("taskId") ?: return START_NOT_STICKY,
                intent.getStringExtra("title") ?: "Download",
            )
            "failed" -> showFailed(
                intent.getStringExtra("taskId") ?: return START_NOT_STICKY,
                intent.getStringExtra("title") ?: "Download",
                intent.getStringExtra("error") ?: "Error",
            )
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

    private fun updateProgress(taskId: String, title: String, progress: Double) {
        activeTasks.add(taskId)
        val percentage = (progress * 100).toInt().coerceIn(0, 100)
        val cancelPI = makeActionPI(taskId, "cancel", 10000)
        val notification = baseBuilder()
            .setContentTitle(title)
            .setContentText("$percentage%")
            .setProgress(100, percentage, false)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancelPI)
            .build()
        getSystemService(NotificationManager::class.java)
            ?.notify(FOREGROUND_ID, notification)
    }

    private fun showCompleted(taskId: String, title: String) {
        activeTasks.remove(taskId)
        val openPI = makeActionPI(taskId, "open", 20000)
        val notification = NotificationCompat.Builder(this, CHANNEL_RESULTS)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Download complete")
            .setContentText(title)
            .setAutoCancel(true)
            .addAction(android.R.drawable.ic_menu_send, "Open", openPI)
            .build()
        val nid = 2000 + (taskId.hashCode().and(0x7FFFFFFF) % 8000)
        getSystemService(NotificationManager::class.java)?.notify(nid, notification)
        if (activeTasks.isEmpty()) stopClean()
    }

    private fun showFailed(taskId: String, title: String, error: String) {
        activeTasks.remove(taskId)
        val retryPI = makeActionPI(taskId, "retry", 30000)
        val notification = NotificationCompat.Builder(this, CHANNEL_RESULTS)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("Download failed")
            .setContentText(title)
            .setAutoCancel(true)
            .addAction(android.R.drawable.ic_menu_rotate, "Retry", retryPI)
            .build()
        val nid = 3000 + (taskId.hashCode().and(0x7FFFFFFF) % 8000)
        getSystemService(NotificationManager::class.java)?.notify(nid, notification)
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
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
}
