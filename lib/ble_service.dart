import 'dart:async';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

// Dış dünyaya (UI) sunduğumuz basit cihaz modeli
class DiscoveredDevice {
  final String id;
  final String name;
  final int rssi;
  DiscoveredDevice({required this.id, required this.name, required this.rssi});
}

// Projenin BLE motorunu yöneten ana sınıf
class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  // Android ve iOS'teki native kodla konuşacağımız ortak kanal
  static const MethodChannel _nativeChannel = MethodChannel('com.example.multipeer/methods');
  static const EventChannel _eventChannel = EventChannel('com.example.multipeer/events');

  Stream<dynamic>? _eventStream;

  // UI (HomePage), native taraftan gelen olayları bu stream üzerinden dinleyecek
  Stream<dynamic> get events {
    _eventStream ??= _eventChannel.receiveBroadcastStream();
    return _eventStream!;
  }
  
  // --- ORTAK KOMUTLAR ---
  // Bu komutlar hem Android hem de iOS native kodunda AYNI isimle karşılanacak
  
  Future<void> startAdvertising({required String deviceId, required String deviceName}) async {
    try {
      final args = {'deviceId': deviceId, 'deviceName': deviceName};
      // iOS ve Android bu tek komutu dinleyecek şekilde ayarlandı.
      await _nativeChannel.invokeMethod('startAdvertising', args);
    } catch (e) {
      print('startAdvertising native çağrısı başarısız: $e');
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await _nativeChannel.invokeMethod('stopAdvertising');
    } catch (e) {
      print('stopAdvertising native çağrısı başarısız: $e');
    }
  }

  Future<void> startScanning() async {
    try {
      await _nativeChannel.invokeMethod('startScanning');
    } catch (e) {
      print('startScanning native çağrısı başarısız: $e');
    }
  }

  Future<void> stopScanning() async {
    try {
      await _nativeChannel.invokeMethod('stopScanning');
    } catch (e) {
      print('stopScanning native çağrısı başarısız: $e');
    }
  }

  // Kaynakları temizlemek için
  void dispose() {
    // Bu servis artık StreamController yönetmediği için dispose'da yapacak bir şeyi yok.
    // Stream'ler native tarafta yönetiliyor.
  }
}
