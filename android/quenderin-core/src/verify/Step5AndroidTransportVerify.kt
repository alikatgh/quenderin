package ai.quenderin.core

import ai.quenderin.app.Step5OkHttpTransport
import java.net.Authenticator
import java.net.CookieHandler
import java.net.CookieManager
import java.net.HttpCookie
import java.net.InetAddress
import java.net.PasswordAuthentication
import java.net.ServerSocket
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/** Localhost protocol fixture only: no actual CUDA host, models or credentials. */
fun main() {
    val listener = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    val base = "http://127.0.0.1:${listener.localPort}"
    val challenged = AtomicInteger(); val redirected = AtomicInteger(); val authCalls = AtomicInteger(); val seen = AtomicInteger()
    val waiting = CountDownLatch(1); val released = CountDownLatch(1)
    val previousAuth = Authenticator.getDefault(); val previousCookies = CookieHandler.getDefault()
    Authenticator.setDefault(object : Authenticator() { override fun getPasswordAuthentication(): PasswordAuthentication { authCalls.incrementAndGet(); return PasswordAuthentication("synthetic", charArrayOf('x')) } })
    CookieHandler.setDefault(CookieManager().apply { cookieStore.add(URI(base), HttpCookie("synthetic-global-cookie", "fixture").apply { path = "/" }) })
    val worker = thread(isDaemon = true, name = "step5-local-fixture") {
        try {
            while (!listener.isClosed) listener.accept().use { socket ->
                socket.soTimeout = 2000; val reader = socket.getInputStream().bufferedReader(Charsets.US_ASCII)
                val request = reader.readLine() ?: return@use; val path = request.split(' ')[1]
                var headerBytes = request.length
                while (true) {
                    val header = reader.readLine() ?: break; headerBytes += header.length; check(headerBytes <= 8192)
                    check(!header.startsWith("Authorization:", true) && !header.startsWith("Proxy-Authorization:", true) && !header.startsWith("Cookie:", true))
                    if (header.isEmpty()) break
                }
                seen.incrementAndGet()
                if (path == "/slow") { waiting.countDown(); released.await(2, TimeUnit.SECONDS); return@use }
                val response = when (path) {
                    "/challenge" -> { challenged.incrementAndGet(); "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=fixture\r\n" }
                    "/proxy" -> "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=fixture\r\n"
                    "/redirect" -> "HTTP/1.1 302 Found\r\nLocation: $base/target\r\n"
                    "/target" -> { redirected.incrementAndGet(); "HTTP/1.1 200 OK\r\n" }
                    else -> "HTTP/1.1 200 OK\r\nSet-Cookie: synthetic-local=fixture; Path=/\r\n"
                }
                socket.getOutputStream().write((response + "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
            }
        } catch (_: java.net.SocketException) { if (!listener.isClosed) throw IllegalStateException("Fixture socket failed.") }
    }
    val executor = Executors.newSingleThreadExecutor()
    try {
        for ((route, status) in listOf("/challenge" to 401, "/redirect" to 302, "/cookie" to 200, "/cookie-again" to 200)) {
            Step5OkHttpTransport().open(URI(base + route), null, 1000).use { check(it.status == status) }
        }
        // A proxy challenge on an explicitly direct connection is a protocol failure.
        check(runCatching { Step5OkHttpTransport().open(URI("$base/proxy"), null, 1000).close() }.isFailure)
        check(challenged.get() == 1 && redirected.get() == 0 && authCalls.get() == 0 && seen.get() == 5)
        val transport = Step5OkHttpTransport()
        val pending = executor.submit<Boolean> { runCatching { transport.open(URI("$base/slow"), null, 1500).close() }.isFailure }
        check(waiting.await(1, TimeUnit.SECONDS)); transport.cancel(); check(pending.get(1, TimeUnit.SECONDS))
        println("Android Step 5 explicit no-auth/no-cookie/no-redirect policy and cancellation passed.")
    } finally {
        released.countDown(); listener.close(); executor.shutdownNow(); worker.join(1000)
        Authenticator.setDefault(previousAuth); CookieHandler.setDefault(previousCookies)
    }
}
