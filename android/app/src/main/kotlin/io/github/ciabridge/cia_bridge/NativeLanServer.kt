package io.github.ciabridge.cia_bridge

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

data class SharedContent(val uri: Uri, val name: String, val size: Long)

data class NativeHostingSession(
    val urls: List<String>,
    val port: Int,
    val totalBytes: Long,
    val usedFallbackPort: Boolean,
)

object NativeServerRegistry {
    @Volatile
    var server: NativeLanServer? = null

    fun stop() {
        val current = server
        server = null
        current?.stop()
    }
}

class NativeLanServer(
    context: Context,
    private val onEvent: (Map<String, Any>) -> Unit,
) {
    private val resolver = context.contentResolver
    private val workers = Executors.newCachedThreadPool()
    private val sessionBytes = AtomicLong(0)
    private var sessionTotal = 0L
    private var socket: ServerSocket? = null
    private var routes: Map<String, SharedContent> = emptyMap()
    @Volatile private var running = false

    fun start(files: List<SharedContent>, advertisedAddress: String, preferredPort: Int): NativeHostingSession {
        require(files.isNotEmpty()) { "Select at least one file" }
        require(preferredPort in 0..65535) { "Invalid HTTP port" }

        var fallback = false
        val listener = try {
            openSocket(preferredPort)
        } catch (error: SocketException) {
            if (preferredPort == 0) throw error
            fallback = true
            openSocket(0)
        }

        val token = randomToken()
        val mapped = LinkedHashMap<String, SharedContent>()
        files.forEachIndexed { index, file ->
            mapped["/$token/${index + 1}/${encodeSegment(file.name)}"] = file
        }
        routes = mapped
        sessionBytes.set(0)
        sessionTotal = files.sumOf(SharedContent::size)
        socket = listener
        running = true
        workers.execute { acceptLoop(listener) }

        val urls = mapped.keys.map { path -> "http://$advertisedAddress:${listener.localPort}$path" }
        return NativeHostingSession(urls, listener.localPort, sessionTotal, fallback)
    }

    @Synchronized
    fun stop() {
        if (!running && socket == null) return
        running = false
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        routes = emptyMap()
        workers.shutdownNow()
        onEvent(mapOf("type" to "stopped"))
    }

    private fun openSocket(port: Int): ServerSocket = ServerSocket().apply {
        reuseAddress = true
        bind(InetSocketAddress("0.0.0.0", port))
    }

    private fun acceptLoop(listener: ServerSocket) {
        while (running) {
            try {
                val client = listener.accept()
                workers.execute { handleClient(client) }
            } catch (error: SocketException) {
                if (running) emitError(error)
                break
            } catch (error: Exception) {
                if (running) emitError(error)
            }
        }
    }

    private fun handleClient(client: Socket) {
        client.use { connection ->
            try {
                connection.soTimeout = 15_000
                val input = BufferedInputStream(connection.getInputStream())
                val output = BufferedOutputStream(connection.getOutputStream())
                val requestLine = readAsciiLine(input) ?: return
                val parts = requestLine.split(' ')
                if (parts.size < 2) return writeStatus(output, 400, "Bad Request")
                val method = parts[0].uppercase(Locale.ROOT)
                val requestPath = parts[1].substringBefore('?')
                val headers = readHeaders(input)
                if (method != "GET" && method != "HEAD") return writeStatus(output, 405, "Method Not Allowed")
                val file = routes[requestPath] ?: return writeStatus(output, 404, "Not Found")
                val range = try {
                    parseRange(headers["range"], file.size)
                } catch (_: IllegalArgumentException) {
                    return writeRangeError(output, file.size)
                }
                sendFile(output, method, file, range)
            } catch (error: Exception) {
                if (running) emitError(error)
            }
        }
    }

    private fun sendFile(output: OutputStream, method: String, file: SharedContent, range: ByteRange) {
        val length = range.endExclusive - range.start
        val status = if (range.partial) "206 Partial Content" else "200 OK"
        val header = buildString {
            append("HTTP/1.1 $status\r\n")
            append("Content-Type: application/octet-stream\r\n")
            append("Content-Length: $length\r\n")
            append("Accept-Ranges: bytes\r\n")
            append("Cache-Control: no-store\r\n")
            append("Content-Disposition: attachment; filename*=UTF-8''${encodeSegment(file.name)}\r\n")
            if (range.partial) append("Content-Range: bytes ${range.start}-${range.endExclusive - 1}/${file.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        output.write(header.toByteArray(StandardCharsets.US_ASCII))
        if (method == "HEAD") {
            output.flush()
            return
        }

        onEvent(
            mapOf(
                "type" to "downloadStarted",
                "fileName" to file.name,
                "fileSize" to file.size,
                "sessionTotal" to sessionTotal,
            ),
        )
        var fileBytes = range.start
        var remaining = length
        openAt(file, range.start).use { source ->
            val buffer = ByteArray(256 * 1024)
            var sinceReport = 0L
            while (running && remaining > 0) {
                val read = source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read < 0) error("Unexpected end of ${file.name}")
                output.write(buffer, 0, read)
                remaining -= read
                fileBytes += read
                sinceReport += read
                val totalSent = sessionBytes.addAndGet(read.toLong())
                if (sinceReport >= 256 * 1024 || remaining == 0L) {
                    sinceReport = 0
                    onEvent(
                        mapOf(
                            "type" to "progress",
                            "fileName" to file.name,
                            "fileBytes" to fileBytes,
                            "fileSize" to file.size,
                            "sessionBytes" to totalSent,
                            "sessionTotal" to sessionTotal,
                        ),
                    )
                }
            }
        }
        output.flush()
        if (remaining == 0L) {
            onEvent(
                mapOf(
                    "type" to "downloadFinished",
                    "fileName" to file.name,
                    "fileSize" to file.size,
                    "sessionBytes" to sessionBytes.get(),
                    "sessionTotal" to sessionTotal,
                ),
            )
        }
    }

    private fun openAt(file: SharedContent, offset: Long): InputStream {
        val descriptor = resolver.openFileDescriptor(file.uri, "r") ?: error("Cannot open ${file.name}")
        val stream = ParcelFileDescriptor.AutoCloseInputStream(descriptor)
        if (offset > 0) {
            try {
                stream.channel.position(offset)
            } catch (_: Exception) {
                stream.close()
                val fallback = resolver.openInputStream(file.uri) ?: error("Cannot open ${file.name}")
                skipFully(fallback, offset)
                return fallback
            }
        }
        return stream
    }

    private fun skipFully(stream: InputStream, count: Long) {
        var remaining = count
        while (remaining > 0) {
            val skipped = stream.skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
            } else if (stream.read() >= 0) {
                remaining--
            } else {
                error("Unexpected end of file while seeking")
            }
        }
    }

    private fun readHeaders(input: InputStream): Map<String, String> {
        val headers = HashMap<String, String>()
        repeat(100) {
            val line = readAsciiLine(input) ?: return headers
            if (line.isEmpty()) return headers
            val separator = line.indexOf(':')
            if (separator > 0) {
                headers[line.substring(0, separator).trim().lowercase(Locale.ROOT)] =
                    line.substring(separator + 1).trim()
            }
        }
        error("Too many HTTP headers")
    }

    private fun readAsciiLine(input: InputStream): String? {
        val data = ArrayList<Byte>(128)
        while (data.size < 8192) {
            val value = input.read()
            if (value < 0) return if (data.isEmpty()) null else String(data.toByteArray(), StandardCharsets.US_ASCII)
            if (value == '\n'.code) break
            if (value != '\r'.code) data.add(value.toByte())
        }
        require(data.size < 8192) { "HTTP header line is too long" }
        return String(data.toByteArray(), StandardCharsets.US_ASCII)
    }

    private fun parseRange(header: String?, size: Long): ByteRange {
        if (header == null) return ByteRange(0, size, false)
        require(header.startsWith("bytes=") && !header.contains(','))
        val spec = header.removePrefix("bytes=")
        val dash = spec.indexOf('-')
        require(dash >= 0)
        val first = spec.substring(0, dash)
        val second = spec.substring(dash + 1)
        val start: Long
        val endExclusive: Long
        if (first.isEmpty()) {
            val suffix = second.toLong()
            require(suffix > 0)
            start = (size - suffix).coerceAtLeast(0)
            endExclusive = size
        } else {
            start = first.toLong()
            require(start in 0 until size)
            endExclusive = if (second.isEmpty()) size else minOf(second.toLong() + 1, size)
            require(endExclusive > start)
        }
        return ByteRange(start, endExclusive, true)
    }

    private fun writeStatus(output: OutputStream, code: Int, reason: String) {
        val body = "$code $reason\n".toByteArray(StandardCharsets.UTF_8)
        output.write(
            "HTTP/1.1 $code $reason\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                .toByteArray(StandardCharsets.US_ASCII),
        )
        output.write(body)
        output.flush()
    }

    private fun writeRangeError(output: OutputStream, size: Long) {
        output.write(
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */$size\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .toByteArray(StandardCharsets.US_ASCII),
        )
        output.flush()
    }

    private fun emitError(error: Exception) {
        onEvent(mapOf("type" to "error", "message" to (error.message ?: error.javaClass.simpleName)))
    }

    private fun randomToken(): String {
        val bytes = ByteArray(12)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun encodeSegment(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")

    private data class ByteRange(val start: Long, val endExclusive: Long, val partial: Boolean)

}
