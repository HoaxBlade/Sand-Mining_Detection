import Flutter
import UIKit
import DJISDK

@main
@objc class AppDelegate: FlutterAppDelegate, DJISDKManagerDelegate, DJIFlightControllerDelegate, DJIBatteryDelegate {

  private var methodChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    methodChannel = FlutterMethodChannel(
      name: "sq.rogue.telemetry_bridge/dji",
      binaryMessenger: controller.binaryMessenger
    )

    methodChannel?.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      switch call.method {
      case "startDJISDK":
        self.registerDJISDK()
        result("iOS SDK registration sequence triggered.")
      case "getSDKStatus":
        let registered = DJISDKManager.hasAppRegistered()
        result(registered)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    
    // Automatically trigger registration on application launch
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      self.registerDJISDK()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - DJI SDK Registration
  private func registerDJISDK() {
    sendConsoleLog("[SDK] Starting iOS DJI SDK registration...")
    DJISDKManager.registerApp(with: self)
  }

  func appRegisteredWithError(_ error: Error?) {
    if let error = error {
      sendConsoleLog("[SDK ERROR] iOS SDK Registration Failed: \(error.localizedDescription)")
      DispatchQueue.main.async {
        self.methodChannel?.invokeMethod("onSDKStatusUpdate", arguments: [
          "status": "FAILED",
          "error": error.localizedDescription
        ])
      }
    } else {
      sendConsoleLog("[SDK] iOS DJI SDK App Key registered successfully!")
      DispatchQueue.main.async {
        self.methodChannel?.invokeMethod("onSDKStatusUpdate", arguments: ["status": "REGISTERED"])
      }
      DJISDKManager.startConnectionToProduct()
    }
  }

  func productConnected(_ product: DJIBaseProduct?) {
    let modelName = product?.model ?? "Unknown Model"
    sendConsoleLog("[DJI] Drone Connected: \(modelName)")
    
    DispatchQueue.main.async {
      self.methodChannel?.invokeMethod("onDJIConnectionUpdate", arguments: true)
    }

    if let aircraft = product as? DJIAircraft {
      if let fc = aircraft.flightController {
        sendConsoleLog("[SDK] Binding to flight controller state callbacks...")
        fc.delegate = self
      }
      if let battery = aircraft.battery {
        sendConsoleLog("[SDK] Binding to battery hardware callbacks...")
        battery.delegate = self
      }
    }
  }

  func productDisconnected() {
    sendConsoleLog("[DJI] Drone Disconnected.")
    DispatchQueue.main.async {
      self.methodChannel?.invokeMethod("onDJIConnectionUpdate", arguments: false)
    }
  }

  // MARK: - DJIFlightControllerDelegate
  func flightController(_ fc: DJIFlightController, didUpdate state: DJIFlightControllerState) {
    let location = state.aircraftLocation
    let lat = location?.latitude ?? 0.0
    let lon = location?.longitude ?? 0.0
    let alt = state.altitude
    
    let vx = state.velocityX
    let vy = state.velocityY
    let speed = sqrt(Double(vx * vx + vy * vy))

    let telemetryData: [String: Any] = [
      "lat": lat,
      "lon": lon,
      "altitude": alt,
      "speed": speed
    ]

    DispatchQueue.main.async {
      self.methodChannel?.invokeMethod("onTelemetryUpdate", arguments: telemetryData)
    }
  }

  // MARK: - DJIBatteryDelegate
  func battery(_ battery: DJIBattery, didUpdateState state: DJIBatteryState) {
    let batPercent = Int(state.chargeRemainingInPercent)
    DispatchQueue.main.async {
      self.methodChannel?.invokeMethod("onBatteryUpdate", arguments: batPercent)
    }
  }

  // MARK: - Helpers
  private func sendConsoleLog(_ message: String) {
    DispatchQueue.main.async {
      self.methodChannel?.invokeMethod("onConsoleLog", arguments: message)
    }
  }
}
