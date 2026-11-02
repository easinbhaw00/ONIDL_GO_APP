package com.onidl.go

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val channelName = "com.onidl.go/torrent"
    private val eventChannelName = "com.onidl.go/torrent_events"
    private val executor = Executors.newSingleThreadExecutor()
    private val poller: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Reattach to the foreground engine after an app relaunch if a queue was saved.
        val queueFile = File(File(filesDir, "torrent_state"), "queue.json")
        if (queueFile.exists() && try { JSONArray(queueFile.readText()).length() > 0 } catch (_: Exception) { false }) {
            startTorrentForegroundService()
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "addMagnet" -> {
                    val magnet = call.argument<String>("magnet")
                    val savePath = call.argument<String>("savePath")
                    if (magnet.isNullOrBlank() || !magnet.startsWith("magnet:") || savePath.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "A valid magnet link and save path are required", null)
                    } else executor.execute {
                        try {
                            startTorrentForegroundService()
                            TorrentEngine.addMagnet(applicationContext, magnet, savePath)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) { runOnUiThread { result.error("TORRENT_ADD_FAILED", e.message, null) } }
                    }
                }
                "addTorrentBytes" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val savePath = call.argument<String>("savePath")
                    if (bytes == null || bytes.isEmpty() || savePath.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Torrent file or save path is missing", null)
                    } else executor.execute {
                        try {
                            startTorrentForegroundService()
                            TorrentEngine.addTorrent(applicationContext, bytes, savePath)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) { runOnUiThread { result.error("TORRENT_ADD_FAILED", e.message, null) } }
                    }
                }
                "pauseAllTorrents", "resumeAllTorrents" -> executor.execute {
                    val pause = call.method == "pauseAllTorrents"
                    if (pause) {
                        TorrentEngine.controlAll(true)
                        stopTorrentForegroundService()
                    } else {
                        startTorrentForegroundService()
                        TorrentEngine.initialize(applicationContext)
                        TorrentEngine.controlAll(false)
                    }
                    runOnUiThread { result.success(true) }
                }
                "pauseTorrent", "resumeTorrent" -> {
                    val id = call.argument<String>("id")
                    if (id.isNullOrBlank()) result.error("INVALID_INPUT", "Torrent ID is missing", null)
                    else executor.execute {
                        try {
                            val pause = call.method == "pauseTorrent"
                            if (!pause) startTorrentForegroundService()
                            val changed = TorrentEngine.control(id, pause)
                            if (changed) runOnUiThread { result.success(true) }
                            else runOnUiThread { result.error("NOT_FOUND", "Torrent is not currently loaded", null) }
                        } catch (e: Exception) { runOnUiThread { result.error("TORRENT_CONTROL_FAILED", e.message, null) } }
                    }
                }
                "getTorrentSnapshot" -> executor.execute { runOnUiThread { result.success(TorrentEngine.snapshot()) } }
                "torrentEngineReady" -> result.success(true)
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                executor.execute { emitTorrentSnapshot() }
            }
            override fun onCancel(arguments: Any?) { eventSink = null }
        })

        poller.scheduleAtFixedRate({ if (eventSink != null) executor.execute { emitTorrentSnapshot() } }, 1, 1, TimeUnit.SECONDS)
    }

    private fun startTorrentForegroundService() {
        // Ask only when the user starts a torrent feature that needs a visible notification.
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4103)
        }
        val intent = Intent(this, TorrentForegroundService::class.java).apply { action = TorrentForegroundService.ACTION_START }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    private fun stopTorrentForegroundService() {
        stopService(Intent(this, TorrentForegroundService::class.java).apply { action = TorrentForegroundService.ACTION_STOP })
    }

    private fun emitTorrentSnapshot() {
        val snapshot = TorrentEngine.snapshot()
        runOnUiThread { eventSink?.success(snapshot) }
    }

    override fun onDestroy() {
        poller.shutdownNow()
        executor.shutdown()
        super.onDestroy()
    }
}
