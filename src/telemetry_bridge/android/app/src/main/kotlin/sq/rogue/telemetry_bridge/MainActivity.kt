package sq.rogue.telemetry_bridge

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayList

// Correct DJI SDK v5 imports
import dji.v5.manager.SDKManager
import dji.v5.manager.interfaces.SDKManagerCallback
import dji.v5.common.register.DJISDKInitEvent
import dji.v5.common.error.IDJIError
import dji.sdk.keyvalue.key.KeyTools
import dji.v5.manager.KeyManager
import dji.sdk.keyvalue.key.FlightControllerKey
import dji.sdk.keyvalue.key.BatteryKey
import dji.sdk.keyvalue.value.common.LocationCoordinate3D
import dji.sdk.keyvalue.value.common.Velocity3D
import dji.v5.common.callback.CommonCallbacks.KeyListener

class MainActivity : FlutterActivity() {
    private val CHANNEL = "sq.rogue.telemetry_bridge/dji"
    private var methodChannel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())

    private val REQUEST_PERMISSION_CODE = 12345
    private val REQUIRED_PERMISSION_LIST: Array<String>
        get() {
            val list = arrayListOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
                Manifest.permission.READ_PHONE_STATE
            )
            if (android.os.Build.VERSION.SDK_INT < 33) {
                list.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
            return list.toTypedArray()
        }

    // Telemetry cache
    private var lat: Double = 0.0
    private var lon: Double = 0.0
    private var altitude: Double = 0.0
    private var speed: Double = 0.0

    private val locationKey = KeyTools.createKey(FlightControllerKey.KeyAircraftLocation3D)
    private val batteryKey = KeyTools.createKey(BatteryKey.KeyChargeRemainingInPercent)
    private val velocityKey = KeyTools.createKey(FlightControllerKey.KeyAircraftVelocity)

    private var isLocationListening = false
    private var isBatteryListening = false
    private var isVelocityListening = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDJISDK" -> {
                    checkAndRequestPermissions()
                    result.success("Initialization and permission checks started.")
                }
                "getSDKStatus" -> {
                    val registered = SDKManager.getInstance().isRegistered
                    result.success(registered)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handler.postDelayed({ checkAndRequestPermissions() }, 1000)
    }

    private fun checkAndRequestPermissions() {
        val missingPermissions = ArrayList<String>()
        for (permission in REQUIRED_PERMISSION_LIST) {
            if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
                missingPermissions.add(permission)
            }
        }

        if (missingPermissions.isNotEmpty()) {
            sendConsoleLog("[SDK] Requesting required runtime permissions...")
            ActivityCompat.requestPermissions(
                this,
                missingPermissions.toTypedArray(),
                REQUEST_PERMISSION_CODE
            )
        } else {
            registerDJISDK()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_PERMISSION_CODE) {
            var allGranted = true
            for (result in grantResults) {
                if (result != PackageManager.PERMISSION_GRANTED) {
                    allGranted = false
                    break
                }
            }
            if (allGranted) {
                sendConsoleLog("[SDK] All permissions granted! Unlocking registration.")
                registerDJISDK()
            } else {
                sendConsoleLog("[SDK ERROR] Missing required permissions. DJI SDK registration aborted.")
            }
        }
    }

    private fun registerDJISDK() {
        sendConsoleLog("[SDK] Starting DJI SDK initialization...")
        
        SDKManager.getInstance().init(applicationContext, object : SDKManagerCallback {
            override fun onInitProcess(event: DJISDKInitEvent?, totalProcess: Int) {
                if (event == DJISDKInitEvent.INITIALIZE_COMPLETE) {
                    sendConsoleLog("[SDK] DJI SDK initialized successfully. Registering App...")
                    SDKManager.getInstance().registerApp()
                }
            }

            override fun onRegisterSuccess() {
                sendConsoleLog("[SDK] DJI SDK App Key registered successfully!")
                handler.post {
                    methodChannel?.invokeMethod("onSDKStatusUpdate", mapOf("status" to "REGISTERED"))
                }
                setupTelemetryListeners()
            }

            override fun onRegisterFailure(error: IDJIError?) {
                sendConsoleLog("[SDK] SDK Registration Failed: ${error?.description()}")
                handler.post {
                    methodChannel?.invokeMethod("onSDKStatusUpdate", mapOf(
                        "status" to "FAILED",
                        "error" to error?.description()
                    ))
                }
            }

            override fun onProductConnect(productId: Int) {
                sendConsoleLog("[DJI] Drone Connected! Product ID: $productId")
                handler.post {
                    methodChannel?.invokeMethod("onDJIConnectionUpdate", true)
                }
                setupTelemetryListeners()
            }

            override fun onProductDisconnect(productId: Int) {
                sendConsoleLog("[DJI] Drone Disconnected. Product ID: $productId")
                handler.post {
                    methodChannel?.invokeMethod("onDJIConnectionUpdate", false)
                }
            }

            override fun onProductChanged(productId: Int) {
                sendConsoleLog("[DJI] Drone product changed. Product ID: $productId")
                handler.post {
                    methodChannel?.invokeMethod("onDJIConnectionUpdate", productId != -1)
                }
                if (productId != -1) {
                    setupTelemetryListeners()
                }
            }

            override fun onDatabaseDownloadProgress(current: Long, total: Long) {
                // Fly Safe database download progress - ignored or logged silently
            }
        })
    }

    private fun setupTelemetryListeners() {
        if (!SDKManager.getInstance().isRegistered) {
            return
        }

        // Listen to GPS Location
        if (!isLocationListening) {
            sendConsoleLog("[SDK] Registering location key listener...")
            KeyManager.getInstance().listen(locationKey, this, object : KeyListener<LocationCoordinate3D> {
                override fun onValueChange(oldValue: LocationCoordinate3D?, newValue: LocationCoordinate3D?) {
                    if (newValue != null) {
                        lat = newValue.latitude
                        lon = newValue.longitude
                        altitude = newValue.altitude
                        sendTelemetryUpdate()
                    }
                }
            })
            isLocationListening = true
        }

        // Listen to Battery Percentage
        if (!isBatteryListening) {
            sendConsoleLog("[SDK] Registering battery key listener...")
            KeyManager.getInstance().listen(batteryKey, this, object : KeyListener<Int> {
                override fun onValueChange(oldValue: Int?, newValue: Int?) {
                    if (newValue != null) {
                        handler.post {
                            methodChannel?.invokeMethod("onBatteryUpdate", newValue)
                        }
                    }
                }
            })
            isBatteryListening = true
        }

        // Listen to Velocity
        if (!isVelocityListening) {
            sendConsoleLog("[SDK] Registering velocity key listener...")
            KeyManager.getInstance().listen(velocityKey, this, object : KeyListener<Velocity3D> {
                override fun onValueChange(oldValue: Velocity3D?, newValue: Velocity3D?) {
                    if (newValue != null) {
                        val vx = newValue.getX()
                        val vy = newValue.getY()
                        val vz = newValue.getZ()
                        speed = Math.sqrt(vx * vx + vy * vy + vz * vz)
                        sendTelemetryUpdate()
                    }
                }
            })
            isVelocityListening = true
        }
    }

    private fun sendTelemetryUpdate() {
        val telemetryData = mapOf(
            "lat" to lat,
            "lon" to lon,
            "altitude" to altitude,
            "speed" to speed
        )
        handler.post {
            methodChannel?.invokeMethod("onTelemetryUpdate", telemetryData)
        }
    }

    private fun sendConsoleLog(message: String) {
        handler.post {
            methodChannel?.invokeMethod("onConsoleLog", message)
        }
    }
}
