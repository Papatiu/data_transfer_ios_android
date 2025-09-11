// ios/Runner/AppDelegate.swift
import UIKit
import Flutter
import CoreBluetooth
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, CLLocationManagerDelegate {
  var multipeer: MultipeerManager?   // (Projenizde varsa) native multipeer wrapper
  var eventSink: FlutterEventSink?
  var locationManager: CLLocationManager?
  var btRequester: BluetoothRequester?

  // channel names (must match Dart)
  let METHOD_CHANNEL = "com.example.multipeer/methods"
  let EVENT_CHANNEL = "com.example.multipeer/events"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // setup location manager for permission requests / delegate events
    self.locationManager = CLLocationManager()
    self.locationManager?.delegate = self

    guard let controller = window?.rootViewController as? FlutterViewController else {
      fatalError("rootViewController is not FlutterViewController")
    }

    let methodChannel = FlutterMethodChannel(name: METHOD_CHANNEL, binaryMessenger: controller.binaryMessenger)
    let eventChannel = FlutterEventChannel(name: EVENT_CHANNEL, binaryMessenger: controller.binaryMessenger)
    eventChannel.setStreamHandler(self)

    methodChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      let args = call.arguments as? [String:Any]

      switch call.method {
      case "startAdvertising":
        let display = args?["displayName"] as? String ?? UIDevice.current.name
        let service = args?["serviceType"] as? String ?? "mpconn"
        // instantiate native multipeer manager if available
        self.multipeer = MultipeerManager(displayName: display, serviceType: service)
        self.multipeer?.setEventSink({ [weak self] evt in
          self?.eventSink?(evt)
        })
        self.multipeer?.startAdvertising()
        result(nil)

      case "startBrowsing":
        let display = args?["displayName"] as? String ?? UIDevice.current.name
        let service = args?["serviceType"] as? String ?? "mpconn"
        self.multipeer = MultipeerManager(displayName: display, serviceType: service)
        self.multipeer?.setEventSink({ [weak self] evt in
          self?.eventSink?(evt)
        })
        self.multipeer?.startBrowsing()
        result(nil)

      case "stop":
        self.multipeer?.stop()
        self.multipeer = nil
        result(nil)

      case "sendData":
        if let typed = args?["data"] as? FlutterStandardTypedData {
          self.multipeer?.sendData(typed.data)
          result(nil)
        } else {
          result(FlutterError(code: "INVALID", message: "No data", details: nil))
        }

      case "invitePeer":
        if let peerId = args?["peerId"] as? String {
          self.multipeer?.invitePeer(byDisplayName: peerId)
          result(nil)
        } else {
          result(FlutterError(code: "INVALID", message: "peerId required", details: nil))
        }

      // --- Native permission helpers used by Dart PermissionGateway ---
      case "getNativePermissions":
        var btAuth = "unavailable"
        if #available(iOS 13.1, *) {
          btAuth = String(describing: CBManager.authorization)
        }
        var locAuth = "unknown"
        if #available(iOS 14.0, *) {
          locAuth = String(describing: self.locationManager?.authorizationStatus ?? CLLocationManager.authorizationStatus())
        } else {
          locAuth = String(describing: CLLocationManager.authorizationStatus())
        }
        let info = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        let hasBonjour = info.joined(separator: ",")
        result(["bluetooth": btAuth, "location": locAuth, "bonjour": hasBonjour])

      case "requestBluetooth":
        // create a central manager to trigger system permission evaluation/prompt
        self.btRequester = BluetoothRequester()
        result(nil)

      case "requestLocationPermission":
        DispatchQueue.main.async {
          self.locationManager?.requestWhenInUseAuthorization()
        }
        result(nil)

      case "triggerLocalNetwork":
        // quick advertise using Multipeer to trigger Local Network prompt (advertise briefly)
        let display = args?["displayName"] as? String ?? UIDevice.current.name
        let service = args?["serviceType"] as? String ?? "mpconn"
        let tmp = MultipeerManager(displayName: display, serviceType: service)
        tmp.setEventSink({ [weak self] evt in
          self?.eventSink?(evt)
        })
        tmp.startAdvertising()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          tmp.stop()
        }
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // FlutterStreamHandler
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    // Send initial location/bluetooth states to Flutter immediately
    var btState = "unknown"
    if #available(iOS 13.1, *) {
      btState = String(describing: CBManager.authorization)
    }
    var locState = "unknown"
    if #available(iOS 14.0, *) {
      locState = String(describing: self.locationManager?.authorizationStatus ?? CLLocationManager.authorizationStatus())
    } else {
      locState = String(describing: CLLocationManager.authorizationStatus())
    }
    events(["event": "nativeInit", "bluetooth": btState, "location": locState])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  // CLLocationManagerDelegate (forward events to Flutter)
  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    var statusStr = "unknown"
    switch status {
    case .notDetermined: statusStr = "notDetermined"
    case .restricted: statusStr = "restricted"
    case .denied: statusStr = "denied"
    case .authorizedAlways: statusStr = "authorizedAlways"
    case .authorizedWhenInUse: statusStr = "authorizedWhenInUse"
    @unknown default: statusStr = "unknown"
    }
    self.eventSink?(["event":"nativeLocationChanged","status":statusStr])
  }
}


// Small helper to create a CBCentralManager which may trigger the Bluetooth permission prompt
class BluetoothRequester: NSObject, CBCentralManagerDelegate {
  private var manager: CBCentralManager?

  override init() {
    super.init()
    self.manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      self?.manager = nil
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // No-op; just instantiation triggers system evaluation/prompt
  }
}
