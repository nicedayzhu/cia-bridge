package io.github.ciabridge.cia_bridge

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var pendingPickerResult: MethodChannel.Result? = null
    private var server: NativeLanServer? = null
    private val patchIoExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFiles" -> launchPicker(result)
                "dataDirectory" -> result.success(filesDir.absolutePath)
                "readFileRange" -> readFileRange(call.arguments, result)
                "listNeighbors" -> listNeighbors(call.arguments, result)
                "startServer" -> startServer(call.arguments, result)
                "stopServer" -> {
                    stopServer()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        pendingPickerResult?.error("activity_destroyed", "The file picker was closed.", null)
        pendingPickerResult = null
        patchIoExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_FILES) return
        val pending = pendingPickerResult
        pendingPickerResult = null
        if (pending == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(emptyList<Map<String, Any>>())
            return
        }
        patchIoExecutor.execute {
            try {
                val value = readPickedFiles(data)
                runOnUiThread { pending.success(value) }
            } catch (error: Exception) {
                runOnUiThread { pending.error("file_picker_failed", error.message, null) }
            }
        }
    }

    private fun launchPicker(result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("picker_busy", "The file picker is already open.", null)
            return
        }
        pendingPickerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_PICK_FILES)
    }

    private fun readPickedFiles(intent: Intent): List<Map<String, Any>> {
        val uris = LinkedHashSet<Uri>()
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        }
        intent.data?.let(uris::add)

        return uris.map { uri ->
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) {
                // Some providers grant access only for the current process.
            }
            val metadata = queryMetadata(uri)
            if (metadata.first.lowercase().endsWith(".zip")) {
                cachePatchArchive(uri, metadata)
            } else {
                mapOf("id" to uri.toString(), "name" to metadata.first, "size" to metadata.second)
            }
        }
    }

    private fun cachePatchArchive(
        uri: Uri,
        metadata: Pair<String, Long>,
    ): Map<String, Any> {
        require(metadata.first.lowercase().endsWith(".zip")) { "Please select a ZIP patch archive" }
        val directory = File(cacheDir, "patch-input").apply { mkdirs() }
        directory.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > PATCH_CACHE_MAX_AGE_MS }
            ?.forEach { runCatching { it.delete() } }
        val target = File(directory, "${UUID.randomUUID()}.zip")
        try {
            val input = contentResolver.openInputStream(uri) ?: error("Cannot open the selected ZIP")
            input.use { source ->
                FileOutputStream(target).use { output -> source.copyTo(output, PATCH_COPY_BUFFER_SIZE) }
            }
            require(target.length() == metadata.second) { "The selected ZIP was not copied completely" }
            return mapOf(
                "id" to uri.toString(),
                "name" to metadata.first,
                "size" to metadata.second,
                "path" to target.absolutePath,
                "temporary" to true,
            )
        } catch (error: Exception) {
            target.delete()
            throw error
        }
    }

    private fun readFileRange(arguments: Any?, result: MethodChannel.Result) {
        Thread {
            try {
                val args = arguments as? Map<*, *> ?: error("Missing file range options")
                val uri = Uri.parse(args["id"] as? String ?: error("Missing file URI"))
                val offset = (args["offset"] as? Number)?.toLong() ?: error("Missing file offset")
                val length = (args["length"] as? Number)?.toInt() ?: error("Missing range length")
                require(offset >= 0) { "File offset must be non-negative" }
                require(length in 0..MAX_METADATA_RANGE_BYTES) { "File range is too large" }
                val bytes = readUriRange(uri, offset, length)
                runOnUiThread { result.success(bytes) }
            } catch (error: Exception) {
                runOnUiThread { result.error("file_range_failed", error.message, null) }
            }
        }.start()
    }

    private fun readUriRange(uri: Uri, offset: Long, length: Int): ByteArray {
        try {
            val descriptor = contentResolver.openFileDescriptor(uri, "r")
                ?: error("Cannot open the selected file")
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { stream ->
                stream.channel.position(offset)
                return readExactly(stream, length)
            }
        } catch (error: IOException) {
            if (offset > MAX_SEQUENTIAL_METADATA_SKIP_BYTES) {
                throw IOException("The Android file provider does not support random access", error)
            }
        }

        val stream = contentResolver.openInputStream(uri)
            ?: error("Cannot reopen the selected file")
        stream.use {
            skipExactly(it, offset)
            return readExactly(it, length)
        }
    }

    private fun skipExactly(stream: InputStream, count: Long) {
        var remaining = count
        while (remaining > 0) {
            val skipped = stream.skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
            } else {
                if (stream.read() < 0) throw EOFException("Unexpected end of selected file")
                remaining--
            }
        }
    }

    private fun readExactly(stream: InputStream, length: Int): ByteArray {
        val bytes = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = stream.read(bytes, offset, length - offset)
            if (read < 0) throw EOFException("Unexpected end of selected file")
            offset += read
        }
        return bytes
    }

    private fun listNeighbors(arguments: Any?, result: MethodChannel.Result) {
        Thread {
            try {
                val localAddress = (arguments as? Map<*, *>)?.get("localAddress") as? String
                val neighbors = readNeighborTable().toMutableList()
                val knownAddresses = neighbors.mapTo(HashSet()) { it["ip"] as String }
                if (localAddress != null) {
                    scanReachableHosts(localAddress)
                        .filterNot(knownAddresses::contains)
                        .forEach { ip ->
                            neighbors.add(
                                mapOf(
                                    "ip" to ip,
                                    "mac" to "",
                                    "candidate" to true,
                                ),
                            )
                        }
                }
                runOnUiThread { result.success(neighbors) }
            } catch (error: Exception) {
                runOnUiThread { result.error("neighbor_scan_failed", error.message, null) }
            }
        }.start()
    }

    private fun readNeighborTable(): List<Map<String, Any>> {
        val found = LinkedHashMap<String, String>()
        try {
            File("/proc/net/arp").forEachLine { line ->
                val columns = line.trim().split(Regex("\\s+"))
                if (columns.size >= 4 && IPV4.matches(columns[0]) && MAC.matches(columns[3])) {
                    val mac = columns[3].uppercase()
                    if (mac != "00:00:00:00:00:00") found[columns[0]] = mac
                }
            }
        } catch (_: Exception) {
            // Newer Android builds may restrict /proc/net/arp.
        }

        if (found.isEmpty()) {
            try {
                val process = ProcessBuilder("/system/bin/ip", "neigh", "show")
                    .redirectErrorStream(true)
                    .start()
                process.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        val match = IP_NEIGH.find(line) ?: return@forEach
                        found[match.groupValues[1]] = match.groupValues[2].uppercase()
                    }
                }
                process.waitFor()
            } catch (_: Exception) {
                // Manual IP remains available when the OS hides its neighbor table.
            }
        }
        return found.map { (ip, mac) ->
            mapOf(
                "ip" to ip,
                "mac" to mac,
                "candidate" to false,
            )
        }
    }

    private fun scanReachableHosts(localAddress: String): List<String> {
        if (!IPV4.matches(localAddress)) return emptyList()
        val octets = localAddress.split('.')
        if (octets.size != 4) return emptyList()
        val prefix = "${octets[0]}.${octets[1]}.${octets[2]}"
        val executor = Executors.newFixedThreadPool(REACHABILITY_THREADS)
        return try {
            val tasks = (1..254)
                .map { "$prefix.$it" }
                .filterNot(localAddress::equals)
                .map { ip ->
                    Callable {
                        try {
                            if (InetAddress.getByName(ip).isReachable(REACHABILITY_TIMEOUT_MS)) ip else null
                        } catch (_: Exception) {
                            null
                        }
                    }
                }
            executor.invokeAll(tasks, REACHABILITY_SCAN_LIMIT_MS, TimeUnit.MILLISECONDS)
                .mapNotNull { future ->
                    if (future.isCancelled) null else runCatching { future.get() }.getOrNull()
                }
                .sortedBy { address -> address.substringAfterLast('.').toIntOrNull() ?: 0 }
        } finally {
            executor.shutdownNow()
        }
    }

    private fun queryMetadata(uri: Uri): Pair<String, Long> {
        var name = uri.lastPathSegment ?: "shared-file.cia"
        var size = -1L
        val cursor: Cursor? = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )
        cursor?.use {
            if (it.moveToFirst()) {
                val nameColumn = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = it.getColumnIndex(OpenableColumns.SIZE)
                if (nameColumn >= 0 && !it.isNull(nameColumn)) name = it.getString(nameColumn)
                if (sizeColumn >= 0 && !it.isNull(sizeColumn)) size = it.getLong(sizeColumn)
            }
        }
        if (size < 0) {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                size = descriptor.length
            }
        }
        require(size >= 0) { "Cannot determine the size of $name" }
        return name to size
    }

    @Suppress("UNCHECKED_CAST")
    private fun startServer(arguments: Any?, result: MethodChannel.Result) {
        try {
            val args = arguments as? Map<String, Any?> ?: error("Missing server options")
            val address = args["address"] as? String ?: error("Missing LAN address")
            val preferredPort = (args["port"] as? Number)?.toInt() ?: 8080
            val rawFiles = args["files"] as? List<Map<String, Any?>> ?: error("Missing files")
            val files = rawFiles.map { raw ->
                SharedContent(
                    uri = Uri.parse(raw["id"] as String),
                    name = raw["name"] as String,
                    size = (raw["size"] as Number).toLong(),
                )
            }

            stopServer()
            val newServer = NativeLanServer(applicationContext, ::emitTransferEvent)
            val session = newServer.start(files, address, preferredPort)
            server = newServer
            NativeServerRegistry.server = newServer
            startKeepAliveService()
            result.success(
                mapOf(
                    "urls" to session.urls,
                    "port" to session.port,
                    "totalBytes" to session.totalBytes,
                    "usedFallbackPort" to session.usedFallbackPort,
                ),
            )
        } catch (error: Exception) {
            result.error("server_start_failed", error.message, null)
        }
    }

    private fun emitTransferEvent(event: Map<String, Any>) {
        runOnUiThread {
            if (::channel.isInitialized) channel.invokeMethod("transferEvent", event)
        }
    }

    private fun stopServer() {
        val current = server
        server = null
        if (NativeServerRegistry.server === current) NativeServerRegistry.server = null
        current?.stop()
        stopService(Intent(this, TransferKeepAliveService::class.java))
    }

    private fun startKeepAliveService() {
        val intent = Intent(this, TransferKeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    companion object {
        private const val CHANNEL = "cia_bridge/native"
        private const val REQUEST_PICK_FILES = 7316
        private const val PATCH_COPY_BUFFER_SIZE = 256 * 1024
        private const val PATCH_CACHE_MAX_AGE_MS = 24L * 60 * 60 * 1000
        private const val REACHABILITY_THREADS = 32
        private const val REACHABILITY_TIMEOUT_MS = 180
        private const val REACHABILITY_SCAN_LIMIT_MS = 2200L
        private const val MAX_METADATA_RANGE_BYTES = 64 * 1024
        private const val MAX_SEQUENTIAL_METADATA_SKIP_BYTES = 4L * 1024 * 1024
        private val IPV4 = Regex("^(?:\\d{1,3}\\.){3}\\d{1,3}$")
        private val MAC = Regex("^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")
        private val IP_NEIGH = Regex("^((?:\\d{1,3}\\.){3}\\d{1,3})\\s+.*?lladdr\\s+((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})")
    }
}
