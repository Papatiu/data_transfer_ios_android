import UIKit
import Flutter
import CoreBluetooth
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, CLLocationManagerDelegate {
  // Native multipeer manager (varsa) - senin mevcut native multipeer implementasyonunu kullan
  var multipeer: MultipeerManager?
  var eventSink: FlutterEventSink?
  var locationManager: CLLocationManager?
  var btRequester: CBCentralManager? // ad-hoc bluetooth trigger

  // channel names (Dart tarafı ile birebir eşleşmeli)
  let METHOD_CHANNEL = "com.example.multipeer/methods"
  let EVENT_CHANNEL = "com.example.multipeer/events"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // register plugins (important for permission_handler etc.)
    GeneratedPluginRegistrant.register(with: self)

    // init locationManager to be able to requestWhenInUseAuthorization and observe changes
    self.locationManager = CLLocationManager()
    self.locationManager?.delegate = self

    // get flutter root view controller
    guard let controller = window?.rootViewController as? FlutterViewController else {
      fatalError("rootViewController is not FlutterViewController")
    }

    // Method / Event channels
    let methodChannel = FlutterMethodChannel(name: METHOD_CHANNEL, binaryMessenger: controller.binaryMessenger)
    let eventChannel = FlutterEventChannel(name: EVENT_CHANNEL, binaryMessenger: controller.binaryMessenger)
    eventChannel.setStreamHandler(self)

    // Observe notifications from BlePeripheralManager (if available) to forward to Flutter
    NotificationCenter.default.addObserver(self, selector: #selector(didStartBleAdvertising(_:)), name: NSNotification.Name("BlePeripheralManagerDidStartAdvertising"), object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(didStopBleAdvertising(_:)), name: NSNotification.Name("BlePeripheralManagerDidStopAdvertising"), object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(didReceiveBleWrite(_:)), name: NSNotification.Name("BlePeripheralManagerDidReceiveWrite"), object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(didUpdateBleState(_:)), name: NSNotification.Name("BlePeripheralManagerDidUpdateState"), object: nil)

    // Method handler
    methodChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      let args = call.arguments as? [String:Any]

      switch call.method {
      // --------------------
      // Cross-platform (Android) advertise / browse (your MainActivity.kt implements these)
      // --------------------
      case "startAdvertising":
        let display = args?["displayName"] as? String ?? UIDevice.current.name
        let service = args?["serviceType"] as? String ?? "mpconn"
        // create native multipeer manager (if you have)
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

      // stop all
      case "stop":
        self.multipeer?.stop()
        self.multipeer = nil
        result(nil)

      // send data via native multipeer
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

      // --------------------
      // iOS-specific BLE advertise (our BlePeripheralManager)
      // --------------------
      case "startAdvertising_iOS":
        let deviceId = args?["deviceId"] as? String ?? UUID().uuidString
        let deviceName = args?["deviceName"] as? String ?? UIDevice.current.name
        let serviceUuid = args?["serviceUuid"] as? String
        // BlePeripheralManager must exist in your project (BlePeripheralManager.shared)
        BlePeripheralManager.shared.startAdvertising(deviceId: deviceId, deviceName: deviceName, serviceUuid: serviceUuid)
        result(nil)

      case "stopAdvertising_iOS":
        BlePeripheralManager.shared.stopAdvertising()
        result(nil)

      // --------------------
      // Helpers: permissions / native triggers
      // --------------------
      case "getNativePermissions":
        var btAuth = "unavailable"
        if #available(iOS 13.1, *) {
          btAuth = String(describing: CBManager.authorization)
        }
        var locAuth = "unknown"
        if #available(iOS 14.0, *) {
          locAuth = String(describing: self.locationManager?.authorizationStatus)
        } else {
          locAuth = String(describing: CLLocationManager.authorizationStatus())
        }
        let info = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        let hasBonjour = info.joined(separator: ",")
        result(["bluetooth": btAuth, "location": locAuth, "bonjour": hasBonjour])

      case "requestBluetooth":
        // instantiate a central briefly to prompt the system permission evaluation
        self.btRequester = CBCentralManager(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        result(nil)

      case "requestLocationPermission":
        DispatchQueue.main.async {
          self.locationManager?.requestWhenInUseAuthorization()
        }
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Notification handlers from BlePeripheralManager
  @objc func didStartBleAdvertising(_ n: Notification) {
    sendEventToFlutter(["event":"bleAdvertisingStarted"])
  }
  @objc func didStopBleAdvertising(_ n: Notification) {
    if let obj = n.object as? [String:Any], let err = obj["error"] as? String {
      sendEventToFlutter(["event":"error","message":"BLE adv stop error: \(err)"])
    } else {
      sendEventToFlutter(["event":"bleAdvertisingStopped"])
    }
  }
  @objc func didReceiveBleWrite(_ n: Notification) {
    if let dict = n.object as? [String:Any], let data = dict["data"] as? Data {
      let arr = [UInt8](data).map { Int($0) }
      sendEventToFlutter(["event":"dataReceived","peerId":"ios-ble-central","data":arr])
    }
  }
  @objc func didUpdateBleState(_ n: Notification) {
    if let raw = n.object as? Int {
      sendEventToFlutter(["event":"bleState","state": raw])
    }
  }

  // Helper to safely send map to Flutter event sink
  func sendEventToFlutter(_ map: [String:Any]) {
    DispatchQueue.main.async {
      self.eventSink?(map)
    }
  }

  // FlutterStreamHandler
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  // CLLocationManagerDelegate - forward state changes
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
