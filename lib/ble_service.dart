import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

// Uuid takma adlarına gerek yok, her şey tek bir amaç için
// DiscoveredDeviceSimple modeli aynı kalıyor
class DiscoveredDeviceSimple {
  final String id;
  final String name;
  final int rssi;
  DiscoveredDeviceSimple({required this.id, required this.name, required this.rssi});
}


class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  static const MethodChannel _nativeChannel = MethodChannel('com.example.multipeer/methods');

  bool _isAdvertising = false;
  bool _isScanning = false;

  final StreamController<DiscoveredDeviceSimple> _foundController = StreamController.broadcast();
  Stream<DiscoveredDeviceSimple> get foundDevices => _foundController.stream;
  
  // startScanning artık native kodu çağırıyor, flutter_reactive_ble kullanmıyoruz.
  Future<void> startScanning() async {
    if (_isScanning) return;
    try {
      await _nativeChannel.invokeMethod('startScanning');
      _isScanning = true;
    } catch (e) {
      print('startScanning native çağrısı başarısız: $e');
    }
  }

  Future<void> stopScanning() async {
    if (!_isScanning) return;
    try {
       await _nativeChannel.invokeMethod('stopScanning');
       _isScanning = false;
    } catch (e) { print('stopScanning native çağrısı başarısız: $e'); }
  }

  // startAdvertising artık platform ayrımı yapmadan tek bir metodu çağırıyor
  Future<void> startAdvertising({required String deviceId, required String deviceName}) async {
    if (_isAdvertising) return;
    try {
        final args = { 'deviceId': deviceId, 'deviceName': deviceName };
        await _nativeChannel.invokeMethod('startAdvertising', args);
        _isAdvertising = true;
    } catch(e) {
        print('startAdvertising native çağrısı başarısız: $e');
    }
  }

  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    try {
        await _nativeChannel.invokeMethod('stopAdvertising');
        _isAdvertising = false;
    } catch (e) { print('stopAdvertising native çağrısı başarısız: $e'); }
  }

  void dispose() {
    _foundController.close();
  }
}