package sq.rogue.telemetry_bridge

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Import DJI SDK classes
import dji.common.error.DJIError
import dji.common.error.DJISDKError
import dji.sdk.base.BaseProduct
import dji.sdk.products.Aircraft
import dji.sdk.sdkmanager.DJISDKManager
import dji.common.flightcontroller.FlightControllerState
import dji.common.battery.BatteryState

class MainActivity : FlutterActivity() {
    private val CHANNEL = "sq.rogue.telemetry_bridge/dji"
    private var methodChannel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDJISDK" -> {
                    registerDJISDK()
                    result.success("Initialization started.")
                }
                "getSDKStatus" -> {
                    val registered = DJISDKManager.getInstance().hasSDKRegistered()
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
        // Automatically start registration on app launch
        handler.postDelayed({ registerDJISDK() }, 1000)
    }

    private fun registerDJISDK() {
        sendConsoleLog("[SDK] Starting DJI SDK registration...")
        
        DJISDKManager.getInstance().registerApp(applicationContext, object : DJISDKManager.SDKManagerCallback {
            override fun onRegister(djiError: DJIError?) {
                if (djiError == DJISDKError.REGISTRATION_SUCCESS) {
                    sendConsoleLog("[SDK] DJI SDK App Key registered successfully!")
                    handler.post {
                        methodChannel?.invokeMethod("onSDKStatusUpdate", mapOf("status" to "REGISTERED"))
                    }
                    startConnectionListener()
                } else {
                    sendConsoleLog("[SDK] SDK Registration Failed: ${djiError?.description}")
                    handler.post {
                        methodChannel?.invokeMethod("onSDKStatusUpdate", mapOf(
                            "status" to "FAILED",
                            "error" to (djiError?.description ?: "Unknown Error")
                        ))
                    }
                }
            }

            override fun onProductDisconnect() {
                sendConsoleLog("[DJI] Drone Disconnected.")
                handler.post {
                    methodChannel?.invokeMethod("onDJIConnectionUpdate", false)
                }
            }

            override fun onProductConnect(product: BaseProduct?) {
                sendConsoleLog("[DJI] Drone Connected: ${product?.model?.displayName}")
                handler.post {
                    methodChannel?.invokeMethod("onDJIConnectionUpdate", true)
                }
                setupTelemetryListeners(product)
            }

            override fun onProductChanged(product: BaseProduct?) {
                sendConsoleLog("[DJI] Drone product changed.")
            }

            override fun onComponentChange(key: BaseProduct.ComponentKey?, oldComponent: dji.sdk.base.BaseComponent?, newComponent: dji.sdk.base.BaseComponent?) {
                sendConsoleLog("[DJI] Accessory component changed: ${key?.name}")
            }

            override fun onInitProcess(p0: dji.common.DJISDKInitEvent?, p1: Int) {
                // DJI SDK init process log
            }

            override fun onDatabaseDownloadProgress(p0: Long, p1: Long) {
                // DJI SDK database download progress log
            }
        })
    }

    private fun startConnectionListener() {
        // Starts background checks to bind immediately if device is already plugged in
        DJISDKManager.getInstance().startConnectionToProduct()
    }

    private fun setupTelemetryListeners(product: BaseProduct?) {
        if (product == null) return

        val aircraft = product as? Aircraft ?: return
        val flightController = aircraft.flightController

        if (flightController != null) {
            sendConsoleLog("[SDK] Binding to flight controller state callbacks...")
            flightController.setStateCallback { state: FlightControllerState ->
                val lat = state.aircraftLocation.latitude
                val lon = state.aircraftLocation.longitude
                val alt = state.aircraftLocation.altitude.toDouble()
                
                // Calculate horizontal speed in m/s from X & Y velocities
                val speed = Math.sqrt(
                    Math.pow(state.velocityX.toDouble(), 2.0) +
                    Math.pow(state.velocityY.toDouble(), 2.0)
                )

                val telemetryData = mapOf(
                    "lat" to lat,
                    "lon" to lon,
                    "altitude" to alt,
                    "speed" to speed
                )

                // Dispatch state payload to Flutter main thread
                handler.post {
                    methodChannel?.invokeMethod("onTelemetryUpdate", telemetryData)
                }
            }
        }

        // Setup battery percentage listener
        val battery = aircraft.battery
        if (battery != null) {
            sendConsoleLog("[SDK] Binding to battery hardware callbacks...")
            battery.setStateCallback { state: BatteryState ->
                val batPercent = state.chargeRemainingInPercent
                handler.post {
                    methodChannel?.invokeMethod("onBatteryUpdate", batPercent)
                }
            }
        }
    }

    private fun sendConsoleLog(message: String) {
        handler.post {
            methodChannel?.invokeMethod("onConsoleLog", message)
        }
    }
}
