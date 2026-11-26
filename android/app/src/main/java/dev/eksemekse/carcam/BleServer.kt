package dev.eksemekse.carcam

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.ParcelUuid
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Obraz po Bluetooth Low Energy: telefon rozgłasza usługę, iPhone odczytuje z niej numer
 * kanału L2CAP (PSM) i otwiera go. Ramki: 4 bajty długości (little-endian) + JPEG.
 */
@SuppressLint("MissingPermission")
class BleServer(private val context: Context, private val onStatus: (String) -> Unit) {
    companion object {
        val SERVICE: UUID = UUID.fromString("7a1c0001-5b0a-4f6e-9d3a-0c5a11ca3e01")
        val PSM_CHAR: UUID = UUID.fromString("7a1c0002-5b0a-4f6e-9d3a-0c5a11ca3e01")
    }

    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? = manager.adapter
    private var gatt: BluetoothGattServer? = null
    private var serverSocket: BluetoothServerSocket? = null
    @Volatile private var output: OutputStream? = null
    @Volatile private var running = false
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
    }

    fun start(): Boolean {
        val bluetooth = adapter
        if (bluetooth == null || !bluetooth.isEnabled) {
            onStatus("Włącz Bluetooth")
            return false
        }
        return try {
            val socket = bluetooth.listenUsingInsecureL2capChannel()
            serverSocket = socket
            psm = socket.psm

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
            server.addService(service)

            running = true
            thread(name = "ble-accept", isDaemon = true) { acceptLoop(socket) }
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
                onStatus("iPhone połączony (Bluetooth)")
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

    fun isConnected(): Boolean = output != null

    /** Zwraca false, gdy nie ma odbiorcy albo zapis się nie udał */
    fun send(jpeg: ByteArray): Boolean {
        val out = output ?: return false
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

    fun stop() {
        running = false
        output = null
        try { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        try { gatt?.close() } catch (_: Exception) {}
    }
}
