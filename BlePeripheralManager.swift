import Foundation
import CoreBluetooth
import UIKit

// Replace with your chosen UUID (same as Android)
fileprivate let DEFAULT_SERVICE_UUID = CBUUID(string: "0000FEED-0000-1000-8000-00805F9B34FB")
fileprivate let DEFAULT_CHAR_UUID = CBUUID(string: "0000BEEF-0000-1000-8000-00805F9B34FB")

final class BlePeripheralManager: NSObject, CBPeripheralManagerDelegate {

    static let shared = BlePeripheralManager()

    private var peripheralManager: CBPeripheralManager!
    private var deviceId: String = ""
    private var deviceName: String = UIDevice.current.name
    private var serviceUuid: CBUUID = DEFAULT_SERVICE_UUID

    // GATT characteristic for write/notify
    private var txCharacteristic: CBMutableCharacteristic?

    // subscribed centrals
    private var subscribedCentrals: [CBCentral] = []

    // state callback via NotificationCenter (app-level)
    static let DidStartAdvertisingNotification = Notification.Name("BlePeripheralManagerDidStartAdvertising")
    static let DidStopAdvertisingNotification = Notification.Name("BlePeripheralManagerDidStopAdvertising")
    static let DidReceiveWriteNotification = Notification.Name("BlePeripheralManagerDidReceiveWrite")
    static let DidUpdateStateNotification = Notification.Name("BlePeripheralManagerDidUpdateState")

    private override init() {
        super.init()
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil, options: nil)
    }

    // MARK: - Public API

    /// Start advertise with small payload (deviceId as service data) and create GATT service
    func startAdvertising(deviceId: String, deviceName: String?, serviceUuid: String?) {
        self.deviceId = deviceId
        if let n = deviceName { self.deviceName = n }
        if let su = serviceUuid, let cuuid = CBUUID(string: su) as CBUUID? {
            self.serviceUuid = cuuid
        } else {
            self.serviceUuid = DEFAULT_SERVICE_UUID
        }

        // If not powered on yet, peripheralManagerDidUpdateState will handle once ready
        if peripheralManager.state == .poweredOn {
            setupGatt()
            advertiseOnce()
        } else {
            // will advertise once state becomes poweredOn
            postStateNotification()
        }
    }

    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        teardownGatt()
        NotificationCenter.default.post(name: BlePeripheralManager.DidStopAdvertisingNotification, object: nil)
    }

    /// Notify / send bytes to subscribed centrals (GATT notify)
    func sendDataToSubscribers(_ data: Data) {
        guard let char = txCharacteristic else { return }
        // chunking may be needed in practice
        let didSend = peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
        // didSend == false means the transmit queue is full — handle peripheralManagerIsReady(toUpdateSubscribers:)
        // You may want to buffer unsent bytes for retry; omitted here for brevity.
        debugPrint("BlePeripheralManager sendDataToSubscribers didSend:\(didSend)")
    }

    // MARK: - Private helpers

    private func advertiseOnce() {
        // Prepare serviceData (limited size) — trim deviceId if long
        var payload = deviceId.data(using: .utf8) ?? Data()
        if payload.count > 20 { payload = payload.subdata(in: 0..<20) } // keep it small

        var adv: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUuid],
            CBAdvertisementDataLocalNameKey: deviceName
        ]

        // Service data dictionary form requires CBUUID key
        adv[CBAdvertisementDataServiceDataKey] = [serviceUuid: payload]

        peripheralManager.startAdvertising(adv)
        NotificationCenter.default.post(name: BlePeripheralManager.DidStartAdvertisingNotification, object: nil)
    }

    private func setupGatt() {
        // Create service + characteristic so centrals can write/subscribe
        let svc = CBMutableService(type: serviceUuid, primary: true)

        // Notify + write without response characteristic
        let props: CBCharacteristicProperties = [.write, .writeWithoutResponse, .notify]
        let perms: CBAttributePermissions = [.writeable]
        let char = CBMutableCharacteristic(type: DEFAULT_CHAR_UUID, properties: props, value: nil, permissions: perms)
        svc.characteristics = [char]
        self.txCharacteristic = char

        // add service (if already exists, ignore)
        peripheralManager.removeAllServices()
        peripheralManager.add(svc)
    }

    private func teardownGatt() {
        subscribedCentrals.removeAll()
        txCharacteristic = nil
        peripheralManager.removeAllServices()
    }

    private func postStateNotification() {
        NotificationCenter.default.post(name: BlePeripheralManager.DidUpdateStateNotification, object: peripheralManager.state.rawValue)
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        debugPrint("BlePeripheralManager state: \(peripheral.state.rawValue)")
        postStateNotification()

        if peripheral.state == .poweredOn {
            // If we have values already set, start advertising
            if !deviceId.isEmpty {
                setupGatt()
                advertiseOnce()
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let e = error {
            debugPrint("didAdd service error: \(e.localizedDescription)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let e = error {
            debugPrint("peripheralManagerDidStartAdvertising error: \(e.localizedDescription)")
            NotificationCenter.default.post(name: BlePeripheralManager.DidStopAdvertisingNotification, object: ["error": e.localizedDescription])
        } else {
            debugPrint("peripheralManagerDidStartAdvertising success")
            NotificationCenter.default.post(name: BlePeripheralManager.DidStartAdvertisingNotification, object: nil)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        debugPrint("central subscribed: \(central.identifier.uuidString)")
        subscribedCentrals.append(central)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        debugPrint("central unsubscribed: \(central.identifier.uuidString)")
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if let data = req.value {
                // Notify app via NotificationCenter
                NotificationCenter.default.post(name: BlePeripheralManager.DidReceiveWriteNotification, object: ["central": req.central, "data": data])
                // optionally respond
                peripheral.respond(to: req, withResult: .success)
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // queue drained — you can resume sending buffered notifications
        debugPrint("peripheralManagerIsReadyToUpdateSubscribers")
    }
}
