package dev.eksemekse.carcam

import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import android.util.Size
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Executors

/** Bierze klatki z kamery, koduje do JPEG i wysyła wybraną drogą (Wi-Fi albo Bluetooth). */
class CameraStreamer(
    private val activity: AppCompatActivity,
    private val previewView: PreviewView,
    private val onStatus: (String) -> Unit
) {
    enum class Mode { WIFI, BLE }

    private class Preset(val width: Int, val jpegQuality: Int, val intervalMs: Long)

    private val executor = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    private var wifi: WifiServer? = null
    private var ble: BleServer? = null

    @Volatile private var mode = Mode.WIFI
    @Volatile private var level = 1
    @Volatile private var lastSent = 0L

    // Poziomy: 0 = niska, 1 = średnia, 2 = wysoka
    private fun preset(): Preset = when (mode) {
        Mode.WIFI -> listOf(Preset(320, 55, 100), Preset(480, 65, 66), Preset(640, 75, 50))[level]
        Mode.BLE -> listOf(Preset(128, 40, 300), Preset(160, 45, 250), Preset(240, 50, 400))[level]
    }

    fun start(mode: Mode, level: Int) {
        stop()
        this.mode = mode
        this.level = level.coerceIn(0, 2)
        when (mode) {
            Mode.WIFI -> {
                wifi = WifiServer().also { it.start() }
                val addresses = localAddresses()
                onStatus(
                    if (addresses.isEmpty()) "Wi-Fi: włącz hotspot albo połącz z siecią"
                    else "Wi-Fi: wpisz w iPhone adres\n$addresses"
                )
            }
            Mode.BLE -> {
                val server = BleServer(activity, onStatus)
                if (!server.start()) return
                ble = server
            }
        }
        bindCamera()
    }

    fun stop() {
        provider?.unbindAll()
        wifi?.stop()
        wifi = null
        ble?.stop()
        ble = null
    }

    private fun bindCamera() {
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            val cameraProvider = future.get()
            provider = cameraProvider

            val preview = Preview.Builder().build()
            preview.setSurfaceProvider(previewView.surfaceProvider)

            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                Size(640, 480),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                            )
                        )
                        .build()
                )
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(executor) { image -> analyze(image) }

            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(activity, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        }, ContextCompat.getMainExecutor(activity))
    }

    private fun analyze(image: ImageProxy) {
        try {
            val p = preset()
            val wifiWants = mode == Mode.WIFI && wifi?.hasClients() == true
            val bleWants = mode == Mode.BLE && ble?.isConnected() == true
            if (!(wifiWants || bleWants)) return
            if (SystemClock.elapsedRealtime() - lastSent < p.intervalMs) return

            val jpeg = encode(image, p)
            if (wifiWants) wifi?.send(jpeg) else ble?.send(jpeg)
            lastSent = SystemClock.elapsedRealtime()
        } catch (_: Exception) {
            // pojedyncza zła klatka nie może zatrzymać strumienia
        } finally {
            image.close()
        }
    }

    private fun encode(image: ImageProxy, p: Preset): ByteArray {
        var bitmap = image.toBitmap()
        val rotation = image.imageInfo.rotationDegrees
        if (rotation != 0) {
            val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
            bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        }
        if (bitmap.width > p.width) {
            val height = bitmap.height * p.width / bitmap.width
            bitmap = Bitmap.createScaledBitmap(bitmap, p.width, height, true)
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, p.jpegQuality, out)
        return out.toByteArray()
    }

    private fun localAddresses(): String =
        (NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList())
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .filter { !it.isLoopbackAddress }
            .joinToString("\n") { "${it.hostAddress}  (podgląd: http://${it.hostAddress}:8080)" }
}
