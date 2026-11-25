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
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the process alive while a page in the built-in browser is playing
 * audio or video, so playback survives the screen turning off or the app
 * going to the background.
 *
 * It deliberately does NOT create a MediaSession: the app's own media player
 * already owns one (audio_service). This service only holds a partial wake
 * lock and posts a low-importance foreground notification, which is what
 * Android requires to keep a background process running.
 */
class BrowserPlaybackService : Service() {
    companion object {
        const val CHANNEL_ID = "vibegrab_browser_playback"
        const val FOREGROUND_ID = 9002
        private const val WAKE_LOCK_TAG = "VibeGrab:BrowserPlayback"

        /// Must be called while the app is in the foreground: Android 12+
        /// rejects a foreground service started from the background.
        fun start(context: Context) {
            val intent = Intent(context, BrowserPlaybackService::class.java)
            intent.putExtra("command", "start")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /// `stopService` is always allowed, even from the background.
        fun stop(context: Context) {
            context.stopService(Intent(context, BrowserPlaybackService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var isForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getStringExtra("command") == "stop") {
            stopClean()
        } else {
            ensureForeground()
        }
        return START_NOT_STICKY
    }

    private fun ensureForeground() {
        if (!isForeground) {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(
                    this,
                    FOREGROUND_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(FOREGROUND_ID, notification)
            }
            isForeground = true
        }
        acquireWakeLock()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {
            android.util.Log.w("VibeGrab", "browser wake lock release failed: ${e.message}")
        }
        wakeLock = null
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_music_note)
            .setContentTitle("VibeGrab")
            .setContentText("Reproducci├│n en segundo plano")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Reproducci├│n en segundo plano",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description =
                    "Mantiene el audio y el v├¡deo del navegador mientras la pantalla est├í apagada"
                setShowBadge(false)
            }
        )
    }

    private fun stopClean() {
        releaseWakeLock()
        isForeground = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
