import UIKit
import Flutter
import CoreBluetooth // Bu ve Flutter import'u kritik

@main
@objc class AppDelegate: FlutterAppDelegate {
    
    private let METHOD_CHANNEL = "com.example.multipeer/methods"
    private let EVENT_CHANNEL = "com.example.multipeer/events"

    private var eventSink: FlutterEventSink?

    // Native BLE Yöneticileri
    private lazy var blePeripheral = BlePeripheralManager.shared
    private lazy var bleCentral = BleCentralManager()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 1. Önce Flutter'ın ana motorunu ve plugin'lerini kaydet. Bu en önemli adım.
        GeneratedPluginRegistrant.register(with: self)
        
        // 2. Flutter'ın ana ViewController'ını güvenli bir şekilde al.
        guard let controller = window?.rootViewController as? FlutterViewController else {
            fatalError("Root view controller, beklenen FlutterViewController değil.")
        }

        // 3. Bizim özel yöneticilerimize, Flutter'a olay gönderebilmeleri için bir yol verelim.
        let eventSender: ([String: Any]) -> Void = { [weak self] map in
            DispatchQueue.main.async {
                self?.eventSink?(map)
            }
        }
        bleCentral.setEventSink(eventSender)
        blePeripheral.setEventSink(eventSender)
        
        // 4. Flutter'dan gelen komutları dinlemek için MethodChannel'ı kur.
        let methodChannel = FlutterMethodChannel(name: METHOD_CHANNEL, binaryMessenger: controller.binaryMessenger)
        
        methodChannel.setMethodCallHandler { [weak self] (call, result) in
             guard let self = self else { return }
             let args = call.arguments as? [String: Any]
            
             switch call.method {
                case "startAdvertising":
                    let deviceId = args?["deviceId"] as? String ?? "iOS_ID_Default"
                    let deviceName = args?["deviceName"] as? String ?? "iPhone"
                    self.blePeripheral.startAdvertising(deviceId: deviceId, deviceName: deviceName, serviceUuid: nil)
                    result(nil)
                case "stopAdvertising":
                    self.blePeripheral.stopAdvertising()
                    result(nil)
                case "startScanning":
                    self.bleCentral.startScanning()
                    result(nil)
                case "stopScanning":
                    self.bleCentral.stopScanning()
                    result(nil)
                // Uyumlu olması için eski iOS'a özel komutları da tutalım
                case "startAdvertising_iOS":
                     let deviceId = args?["deviceId"] as? String ?? "iOS_ID_Default"
                    let deviceName = args?["deviceName"] as? String ?? "iPhone"
                    self.blePeripheral.startAdvertising(deviceId: deviceId, deviceName: deviceName, serviceUuid: nil)
                    result(nil)
                case "stopAdvertising_iOS":
                    self.blePeripheral.stopAdvertising()
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
             }
        }
        
        // 5. Flutter'a olayları göndermek için EventChannel'ı kur.
        let eventChannel = FlutterEventChannel(name: EVENT_CHANNEL, binaryMessenger: controller.binaryMessenger)
        eventChannel.setStreamHandler(self) // Kendimizi stream handler olarak atıyoruz.
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

// EventChannel'ı yönetmek için bu extension'ı kullanmak daha temiz bir yöntemdir.
extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
