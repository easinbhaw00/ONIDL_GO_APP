package com.onidl.go

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import java.io.File

/**
 * Android 15 does not allow BOOT_COMPLETED receivers to start dataSync foreground
 * services. We therefore show a reminder instead of silently starting P2P traffic.
 * The user opens ONIDL Go; MainActivity then restores the saved torrent queue.
 */
class TorrentBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            val queueFile = File(File(context.filesDir, "torrent_state"), "queue.json")
            if (!queueFile.exists()) return
            val queue = JSONArray(queueFile.readText())
            if (queue.length() == 0) return

            val manager = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        TorrentForegroundService.CHANNEL_ID,
                        "Torrent downloads",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply { description = "Torrent recovery reminders" }
                )
            }
            val openApp = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("restore_torrents_after_boot", true)
            }
            val pending = PendingIntent.getActivity(
                context, 4102, openApp,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(context, TorrentForegroundService.CHANNEL_ID)
            else Notification.Builder(context)

            manager.notify(
                4102,
                builder.setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle("ONIDL Go downloads are ready")
                    .setContentText("Open ONIDL Go to restore ${queue.length()} torrent(s)")
                    .setContentIntent(pending)
                    .setAutoCancel(true)
                    .build()
            )
        } catch (_: SecurityException) {
            // Notification permission may be denied. The queue remains saved and
            // will still be restored the next time the user opens the app.
        } catch (_: Exception) {
            // A malformed or inaccessible queue must not crash the boot process.
        }
    }
}
