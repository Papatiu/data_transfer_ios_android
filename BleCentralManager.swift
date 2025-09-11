// ios/Runner/BleCentralManager.swift
import Foundation
import CoreBluetooth
import CoreLocation

class BleCentralManager: NSObject, CBCentralManagerDelegate {
  static let shared = BleCentralManager()
  private var center: CBCentralManager?
  var eventSink: FlutterEventSink?
  var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

  private let serviceUUID = CBUUID(string: "0000feed-0000-1000-8000-00805f9b34fb")

  func startScanning() {
    if center == nil {
      center = CBCentralManager(delegate: self, queue: nil)
    }
    // If already powered on, start immediately
    if center?.state == .poweredOn {
      center?.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
      eventSink?(["event":"bleScanningStarted"])
    }
  }

  func stopScanning() {
    center?.stopScan()
    eventSink?(["event":"stopped"])
  }

  // CBCentralManagerDelegate
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
      case .poweredOn:
        // Save status
        locationAuthorizationStatus = CLLocationManager.authorizationStatus()
        // start scanning
        center?.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
      default:
        break
    }
    eventSink?(["event":"bleCentralState","state":String(describing: central.state)])
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
    var name = peripheral.name ?? "Unknown"
    if let svcData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID:Data] {
      if let d = svcData[serviceUUID], let str = String(data: d, encoding: .utf8) {
        // advertisement service data contains our small JSON
        name = str
      }
    } else if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
      name = localName
    }
    eventSink?(["event":"peerFound","peerId":peripheral.identifier.uuidString,"displayName":name,"rssi":RSSI.intValue])
  }
}
