package com.onidl.go

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/** Owns the process-wide libtorrent engine lifecycle while transfers are active. */
class TorrentForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "onidl_torrent_downloads"
        const val NOTIFICATION_ID = 4101
        const val ACTION_STOP = "com.onidl.go.action.STOP_TORRENT_SERVICE"
        const val ACTION_START = "com.onidl.go.action.START_TORRENT_SERVICE"
    }
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable {
        override fun run() {
            val snapshot = TorrentEngine.snapshot()
            val count = maxOf(snapshot.size, TorrentEngine.queuedCount(applicationContext))
            val active = snapshot.count { it["paused"] != true && it["finished"] != true }
            updateNotification(count, active)
            handler.postDelayed(this, 5000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Torrent downloads", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows active ONIDL Go torrent transfers"
                setShowBadge(false)
            })
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            handler.removeCallbacks(refresh)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundCompat(buildNotification("Starting torrent engine…"))
        try {
            TorrentEngine.initialize(applicationContext)
            TorrentEngine.onChanged = { handler.post {
                val snapshot = TorrentEngine.snapshot()
                updateNotification(maxOf(snapshot.size, TorrentEngine.queuedCount(applicationContext)), snapshot.count { it["paused"] != true && it["finished"] != true })
            } }
            handler.removeCallbacks(refresh)
            handler.post(refresh)
        } catch (e: Exception) {
            updateNotification(0, 0)
        }
        return START_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(message: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("ONIDL Go · Torrent engine")
            .setContentText(message)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(true).setOnlyAlertOnce(true).build()
    }

    private fun updateNotification(total: Int, active: Int) {
        val message = if (total == 0) "Torrent engine is ready" else "$active active · $total in queue"
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(message))
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Keep the foreground engine alive when the task is swiped away; Android may still stop it.
        super.onTaskRemoved(rootIntent)
    }

    /** Android 15 dataSync foreground services have a shared six-hour daily limit. */
    @androidx.annotation.RequiresApi(35)
    override fun onTimeout(startId: Int, fgsType: Int) {
        handler.removeCallbacks(refresh)
        // The persistent queue is already on disk; the next user launch restores it.
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
    }

    override fun onDestroy() {
        handler.removeCallbacks(refresh)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
