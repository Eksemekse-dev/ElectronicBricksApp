package dev.eksemekse.carcam

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Obraz po Bluetooth Low Energy. Telefon rozgłasza usługę. Dwa sposoby przesyłu:
 *  - Android 10+: kanał L2CAP (szybszy); iPhone odczytuje jego numer (PSM) z charakterystyki.
 *  - starszy Android: powiadomienia GATT (wolniejsze); PSM = 0, iPhone włącza powiadomienia.
 * Ramki w obu wypadkach: 4 bajty długości (little-endian) + JPEG.
 */
@SuppressLint("MissingPermission")
class BleServer(private val context: Context, private val onStatus: (String) -> Unit) {
    companion object {
        val SERVICE: UUID = UUID.fromString("7a1c0001-5b0a-4f6e-9d3a-0c5a11ca3e01")
        val PSM_CHAR: UUID = UUID.fromString("7a1c0002-5b0a-4f6e-9d3a-0c5a11ca3e01")
        val DATA_CHAR: UUID = UUID.fromString("7a1c0003-5b0a-4f6e-9d3a-0c5a11ca3e01")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? = manager.adapter
    private var gatt: BluetoothGattServer? = null
    private var serverSocket: BluetoothServerSocket? = null
    private var dataChar: BluetoothGattCharacteristic? = null
    @Volatile private var output: OutputStream? = null
    @Volatile private var subscriber: BluetoothDevice? = null
    @Volatile private var chunkSize = 20
    @Volatile private var running = false
    private val notificationSent = Semaphore(0)
    private var psm = 0

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            onStatus("Czekam na iPhone'a (Bluetooth)")
        }

        override fun onStartFailure(errorCode: Int) {
            onStatus("Błąd rozgłaszania Bluetooth: $errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            advertise()
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            chunkSize = (mtu - 3).coerceAtLeast(20)
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED && subscriber?.address == device.address) {
                subscriber = null
                if (running) advertise()
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            val value = byteArrayOf((psm and 0xFF).toByte(), ((psm shr 8) and 0xFF).toByte())
            val part = value.copyOfRange(minOf(offset, value.size), value.size)
            gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, part)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (descriptor.uuid == CCCD) {
                val enabled = value.isNotEmpty() && value[0].toInt() == 1
                subscriber = if (enabled) device else null
                onStatus(if (enabled) "iPhone połączony (Bluetooth, tryb powiadomień)" else "Czekam na iPhone'a (Bluetooth)")
            }
            if (responseNeeded) {
                gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            notificationSent.release()
        }
    }

    fun start(): Boolean {
        val bluetooth = adapter
        if (bluetooth == null || !bluetooth.isEnabled) {
            onStatus("Włącz Bluetooth")
            return false
        }
        return try {
            // Szybki kanał L2CAP tylko na Androidzie 10+
            val socket: BluetoothServerSocket? =
                if (Build.VERSION.SDK_INT >= 29) bluetooth.listenUsingInsecureL2capChannel() else null
            serverSocket = socket
            psm = if (socket != null && Build.VERSION.SDK_INT >= 29) socket.psm else 0

            val server = manager.openGattServer(context, gattCallback)
            gatt = server

            val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(
                BluetoothGattCharacteristic(
                    PSM_CHAR,
                    BluetoothGattCharacteristic.PROPERTY_READ,
                    BluetoothGattCharacteristic.PERMISSION_READ
                )
            )
            val data = BluetoothGattCharacteristic(
                DATA_CHAR,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            data.addDescriptor(
                BluetoothGattDescriptor(
                    CCCD,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
            dataChar = data
            service.addCharacteristic(data)
            server.addService(service)

            running = true
            if (socket != null) {
                thread(name = "ble-accept", isDaemon = true) { acceptLoop(socket) }
            }
            true
        } catch (e: Exception) {
            onStatus("Błąd Bluetooth: ${e.message}")
            false
        }
    }

    private fun advertise() {
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            onStatus("Ten telefon nie potrafi rozgłaszać przez BLE")
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE))
            .build()
        advertiser.stopAdvertising(advertiseCallback)
        advertiser.startAdvertising(settings, data, advertiseCallback)
    }

    private fun acceptLoop(socket: BluetoothServerSocket) {
        while (running) {
            try {
                val client = socket.accept()
                output = client.outputStream
                onStatus("iPhone połączony (Bluetooth, kanał L2CAP)")
                try {
                    val input = client.inputStream
                    // iPhone nic nie wysyła; odczyt kończy się, gdy zamknie kanał
                    while (running && input.read() >= 0) { /* nic */ }
                } catch (_: IOException) {
                } finally {
                    output = null
                    try { client.close() } catch (_: IOException) {}
                }
                if (running) advertise()
            } catch (_: IOException) {
                return
            }
        }
    }

    fun isConnected(): Boolean = output != null || subscriber != null

    /** Zwraca false, gdy nie ma odbiorcy albo zapis się nie udał */
    fun send(jpeg: ByteArray): Boolean {
        val out = output
        if (out != null) {
            return try {
                val header = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(jpeg.size).array()
                out.write(header)
                out.write(jpeg)
                out.flush()
                true
            } catch (_: IOException) {
                output = null
                false
            }
        }
        val device = subscriber ?: return false
        return notifyFrame(device, jpeg)
    }

    /** Powiadomienia GATT: ramka w kawałkach, każdy czeka na potwierdzenie wysłania */
    private fun notifyFrame(device: BluetoothDevice, jpeg: ByteArray): Boolean {
        val server = gatt ?: return false
        val characteristic = dataChar ?: return false
        val frame = ByteBuffer.allocate(4 + jpeg.size).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(jpeg.size).put(jpeg).array()

        notificationSent.drainPermits()
        var offset = 0
        while (offset < frame.size) {
            val end = minOf(offset + chunkSize, frame.size)
            characteristic.value = frame.copyOfRange(offset, end)
            if (!server.notifyCharacteristicChanged(device, characteristic, false)) return false
            if (!notificationSent.tryAcquire(1, TimeUnit.SECONDS)) return false
            offset = end
        }
        return true
    }

    fun stop() {
        running = false
        output = null
        subscriber = null
        try { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        try { gatt?.close() } catch (_: Exception) {}
    }
}
