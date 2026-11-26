package dev.eksemekse.carcam

import android.Manifest
import android.os.Build
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.Spinner
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.view.PreviewView

class MainActivity : AppCompatActivity() {
    private lateinit var streamer: CameraStreamer
    private lateinit var status: TextView
    private lateinit var wifiRadio: RadioButton
    private lateinit var bleRadio: RadioButton
    private lateinit var qualitySpinner: Spinner
    private lateinit var toggle: Button
    private var running = false

    private val permissionRequest =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            if (result.values.all { it }) startStreaming() else status.text = "Brak wymaganych uprawnień"
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        val preview = PreviewView(this)
        root.addView(preview, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val modeGroup = RadioGroup(this).apply { orientation = RadioGroup.HORIZONTAL }
        wifiRadio = RadioButton(this).apply { text = "Wi-Fi" }
        bleRadio = RadioButton(this).apply { text = "Bluetooth" }
        modeGroup.addView(wifiRadio)
        modeGroup.addView(bleRadio)
        modeGroup.check(wifiRadio.id)
        root.addView(modeGroup)

        qualitySpinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                listOf("Jakość: niska", "Jakość: średnia", "Jakość: wysoka")
            )
            setSelection(1)
        }
        root.addView(qualitySpinner)

        status = TextView(this).apply { text = "Zatrzymano" }
        root.addView(status)

        toggle = Button(this).apply { text = "Start" }
        root.addView(toggle)
        setContentView(root)

        streamer = CameraStreamer(this, preview) { text -> runOnUiThread { status.text = text } }

        toggle.setOnClickListener {
            if (running) stopStreaming() else permissionRequest.launch(neededPermissions())
        }
    }

    private fun neededPermissions(): Array<String> {
        val list = mutableListOf(Manifest.permission.CAMERA)
        if (bleRadio.isChecked && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list += Manifest.permission.BLUETOOTH_ADVERTISE
            list += Manifest.permission.BLUETOOTH_CONNECT
        }
        return list.toTypedArray()
    }

    private fun startStreaming() {
        val mode = if (bleRadio.isChecked) CameraStreamer.Mode.BLE else CameraStreamer.Mode.WIFI
        streamer.start(mode, qualitySpinner.selectedItemPosition)
        running = true
        toggle.text = "Stop"
        wifiRadio.isEnabled = false
        bleRadio.isEnabled = false
    }

    private fun stopStreaming() {
        streamer.stop()
        running = false
        toggle.text = "Start"
        wifiRadio.isEnabled = true
        bleRadio.isEnabled = true
        status.text = "Zatrzymano"
    }

    override fun onDestroy() {
        streamer.stop()
        super.onDestroy()
    }
}
