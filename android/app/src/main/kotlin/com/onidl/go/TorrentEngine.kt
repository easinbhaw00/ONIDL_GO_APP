package com.onidl.go

import android.content.Context
import org.libtorrent4j.Alert
import org.libtorrent4j.AlertListener
import org.libtorrent4j.AlertType
import org.libtorrent4j.SessionManager
import org.libtorrent4j.TorrentHandle
import org.libtorrent4j.TorrentInfo
import org.libtorrent4j.alerts.AddTorrentAlert
import org.libtorrent4j.swig.torrent_flags_t
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** Process-wide torrent engine. The foreground Service initializes and owns its lifecycle. */
object TorrentEngine {
    private val lock = Any()
    private val handles = ConcurrentHashMap<String, TorrentHandle>()
    private val paused = ConcurrentHashMap<String, Boolean>()
    @Volatile private var manager: SessionManager? = null
    @Volatile private var initialized = false
    @Volatile private var restored = false
    @Volatile var onChanged: (() -> Unit)? = null

    fun initialize(context: Context) {
        synchronized(lock) {
            if (initialized) return
            val app = context.applicationContext
            val session = SessionManager()
            session.start()
            session.startDht()
            session.addListener(object : AlertListener {
                override fun types(): IntArray = intArrayOf(AlertType.ADD_TORRENT.swig())
                override fun alert(alert: Alert<*>) {
                    if (alert is AddTorrentAlert) {
                        try {
                            val handle = alert.handle()
                            if (handle.isValid) {
                                val id = handle.infoHash().toHex()
                                handles[id] = handle
                                paused.putIfAbsent(id, false)
                            }
                        } catch (_: Exception) { }
                        onChanged?.invoke()
                    }
                }
            })
            manager = session
            initialized = true
            restoreQueue(app)
        }
    }

    private fun stateDir(context: Context) = File(context.filesDir, "torrent_state").apply { mkdirs() }
    private fun queueFile(context: Context) = File(stateDir(context), "queue.json")

    @Synchronized private fun saveQueue(context: Context, item: JSONObject) {
        val file = queueFile(context)
        val queue = if (file.exists()) try { JSONArray(file.readText()) } catch (_: Exception) { JSONArray() } else JSONArray()
        val type = item.optString("type")
        val value = item.optString("value")
        for (i in 0 until queue.length()) {
            val old = queue.optJSONObject(i) ?: continue
            if (old.optString("type") == type && old.optString("value") == value) return
        }
        queue.put(item)
        val temp = File(file.parentFile, "queue.json.tmp")
        temp.writeText(queue.toString())
        if (file.exists() && !file.delete()) throw IllegalStateException("Could not replace torrent queue")
        if (!temp.renameTo(file)) {
            temp.copyTo(file, overwrite = true)
            temp.delete()
        }
    }

    fun queuedCount(context: Context): Int {
        val file = queueFile(context)
        if (!file.exists()) return 0
        return try { JSONArray(file.readText()).length() } catch (_: Exception) { 0 }
    }

    private fun restoreQueue(context: Context) {
        if (restored) return
        restored = true
        val file = queueFile(context)
        if (!file.exists()) return
        val queue = try { JSONArray(file.readText()) } catch (_: Exception) { JSONArray() }
        val session = manager ?: return
        for (i in 0 until queue.length()) {
            val item = queue.optJSONObject(i) ?: continue
            try {
                val oldPath = item.optString("savePath")
                val destination = File(oldPath.ifBlank { File(context.getExternalFilesDir(null), "ONIDL Go").absolutePath }).apply { mkdirs() }
                when (item.optString("type")) {
                    "magnet" -> {
                        val magnet = item.optString("value")
                        if (magnet.startsWith("magnet:")) session.download(magnet, destination, torrent_flags_t.from_int(0))
                    }
                    "file" -> {
                        val torrentFile = File(item.optString("value"))
                        if (torrentFile.exists()) {
                            val info = TorrentInfo.bdecode(torrentFile.readBytes())
                            if (info.isValid) session.download(info, destination)
                        }
                    }
                }
            } catch (_: Exception) { }
        }
        onChanged?.invoke()
    }

    fun addMagnet(context: Context, magnet: String, savePath: String) {
        initialize(context)
        val destination = File(savePath).apply { mkdirs() }
        saveQueue(context, JSONObject().put("type", "magnet").put("value", magnet).put("savePath", destination.absolutePath))
        manager!!.download(magnet, destination, torrent_flags_t.from_int(0))
    }

    fun addTorrent(context: Context, bytes: ByteArray, savePath: String) {
        initialize(context)
        val info = TorrentInfo.bdecode(bytes)
        require(info.isValid) { "Invalid torrent file" }
        val destination = File(savePath).apply { mkdirs() }
        val torrentFile = File(stateDir(context), "import_${System.currentTimeMillis()}.torrent")
        torrentFile.writeBytes(bytes)
        saveQueue(context, JSONObject().put("type", "file").put("value", torrentFile.absolutePath).put("savePath", destination.absolutePath))
        manager!!.download(info, destination)
    }

    fun controlAll(pauseAll: Boolean) {
        handles.forEach { (id, handle) ->
            try { if (handle.isValid) { if (pauseAll) handle.pause() else handle.resume(); paused[id] = pauseAll } } catch (_: Exception) { }
        }
        onChanged?.invoke()
    }

    fun control(id: String, pauseOne: Boolean): Boolean {
        val handle = handles[id] ?: return false
        if (!handle.isValid) return false
        if (pauseOne) handle.pause() else handle.resume()
        paused[id] = pauseOne
        onChanged?.invoke()
        return true
    }

    fun hasActiveOrQueued(): Boolean = handles.values.any { try { it.isValid && !it.status().isFinished() && paused[it.infoHash().toHex()] != true } catch (_: Exception) { false } }

    fun snapshot(): List<Map<String, Any>> {
        val result = ArrayList<Map<String, Any>>()
        handles.entries.forEach { entry ->
            val handle = entry.value
            try {
                if (!handle.isValid) return@forEach
                val status = handle.status()
                val name = try { handle.status(TorrentHandle.QUERY_NAME).name() } catch (_: Exception) { "" }
                result.add(mapOf(
                    "id" to entry.key,
                    "name" to name.ifBlank { "Fetching torrent metadata…" },
                    "progress" to status.progress().toDouble().coerceIn(0.0, 1.0),
                    "downloadRate" to status.downloadRate().toDouble(),
                    "uploadRate" to status.uploadRate().toDouble(),
                    "downloaded" to status.totalWantedDone().toDouble(),
                    "total" to status.totalWanted().toDouble(),
                    "peers" to status.numPeers(),
                    "seeds" to status.numSeeds(),
                    "state" to status.state().toString(),
                    "paused" to (paused[entry.key] ?: false),
                    "finished" to status.isFinished()
                ))
            } catch (_: Exception) { }
        }
        return result
    }
}
