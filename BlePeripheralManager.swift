import Foundation
import CoreBluetooth

class BlePeripheralManager: NSObject, CBPeripheralManagerDelegate {
  static let shared = BlePeripheralManager()
  private var manager: CBPeripheralManager?
  var eventSink: FlutterEventSink?

  private let serviceUUID = CBUUID(string: "0000feed-0000-1000-8000-00805f9b34fb")
  private var advertising = false

  func startAdvertising(deviceId: String, deviceName: String) {
    if manager == nil {
      manager = CBPeripheralManager(delegate: self, queue: nil)
    }
    // If poweredOn, advertise immediately else wait in delegate
    if manager?.state == .poweredOn {
      advertise(deviceId: deviceId, deviceName: deviceName)
    } // else delegate will call advertise when poweredOn
  }

  private func advertise(deviceId: String, deviceName: String) {
    stopAdvertising()
    let payloadDict: [String:String] = ["id": String(deviceId.prefix(6)), "n": String(deviceName.prefix(10))]
    if let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: []) {
      // service data map
      let advData: [String:Any] = [
        CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
        CBAdvertisementDataLocalNameKey: deviceName,
        CBAdvertisementDataServiceDataKey: [serviceUUID: data]
      ]
      manager?.startAdvertising(advData)
      advertising = true
      eventSink?(["event":"advertisingStarted"])
    } else {
      eventSink?(["event":"error","message":"advertise payload encode failed"])
    }
  }

  func stopAdvertising() {
    if advertising {
      manager?.stopAdvertising()
      advertising = false
      eventSink?(["event":"stopped"])
    }
  }

  // CBPeripheralManagerDelegate
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
      case .poweredOn:
        // optionally notify
        eventSink?(["event":"blePeripheralState","state":"poweredOn"])
      case .poweredOff:
        eventSink?(["event":"blePeripheralState","state":"poweredOff"])
      default: break
    }
  }
}
