package dev.eksemekse.carcam

import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/**
 * Serwer obrazu po Wi-Fi.
 *  - /raw    : strumień dla aplikacji na iPhone (application/octet-stream)
 *  - każda inna ścieżka (np. /): MJPEG do podglądu w przeglądarce
 * Ramki w obu wypadkach mają ten sam format: "--frame", nagłówki z Content-Length, JPEG.
 */
class WifiServer(private val port: Int = 8080) {
    private class Client(val socket: Socket, val out: OutputStream)

    private var server: ServerSocket? = null
    private val clients = CopyOnWriteArrayList<Client>()
    @Volatile private var running = false

    fun start() {
        running = true
        thread(name = "wifi-accept", isDaemon = true) {
            try {
                val s = ServerSocket(port)
                server = s
                while (running) {
                    val socket = s.accept()
                    thread(name = "wifi-client", isDaemon = true) { handle(socket) }
                }
            } catch (_: Exception) {
                // gniazdo zamknięte przy zatrzymaniu
            }
        }
    }

    private fun handle(socket: Socket) {
        var client: Client? = null
        try {
            socket.tcpNoDelay = true
            val input = socket.getInputStream()

            val request = StringBuilder()
            while (request.length < 4096) {
                val b = input.read()
                if (b < 0) return
                request.append(b.toChar())
                if (request.endsWith("\r\n\r\n")) break
            }
            val contentType = if (request.startsWith("GET /raw")) {
                "application/octet-stream"
            } else {
                "multipart/x-mixed-replace; boundary=frame"
            }

            val out = socket.getOutputStream()
            out.write(
                ("HTTP/1.0 200 OK\r\nContent-Type: $contentType\r\n" +
                    "Cache-Control: no-cache\r\nConnection: close\r\n\r\n").toByteArray()
            )
            out.flush()
            client = Client(socket, out).also { clients.add(it) }

            // Czekamy, aż klient się rozłączy
            while (input.read() >= 0) { /* nic nie oczekujemy */ }
        } catch (_: Exception) {
        } finally {
            client?.let { clients.remove(it) }
            try { socket.close() } catch (_: Exception) {}
        }
    }

    fun hasClients(): Boolean = clients.isNotEmpty()

    fun send(jpeg: ByteArray) {
        val header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.size}\r\n\r\n".toByteArray()
        for (c in clients) {
            try {
                c.out.write(header)
                c.out.write(jpeg)
                c.out.write("\r\n".toByteArray())
                c.out.flush()
            } catch (_: Exception) {
                clients.remove(c)
                try { c.socket.close() } catch (_: Exception) {}
            }
        }
    }

    fun stop() {
        running = false
        try { server?.close() } catch (_: Exception) {}
        clients.forEach { try { it.socket.close() } catch (_: Exception) {} }
        clients.clear()
    }
}
