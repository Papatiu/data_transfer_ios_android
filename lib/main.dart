import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart' as uuid_gen;
import 'ble_service.dart';

//******************************************************************
// GİRİŞ NOKTASI VE METHODCHANNEL
//******************************************************************
const MethodChannel nativeChannel = MethodChannel('com.example.multipeer/methods');

void main() {
  runApp(const MyApp());
}

//******************************************************************
// ANA UYGULAMA WIDGET'I
//******************************************************************
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hayat Köprüsü',
      home: PermissionGateway(), // Önce İzinleri al
    );
  }
}

//******************************************************************
// AKILLI İZİN EKRANI
//******************************************************************
class PermissionGateway extends StatefulWidget {
  const PermissionGateway({super.key});
  @override
  State<PermissionGateway> createState() => _PermissionGatewayState();
}

class _PermissionGatewayState extends State<PermissionGateway> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkAndRequest();
  }

  Future<void> _checkAndRequest() async {
    if (!mounted) return;
    setState(() => _checking = true);
    
    // Her platform için doğru izin listesini oluştur ve iste.
    final allGranted = await requestBlePermissions();

    if (!mounted) return;
    if (allGranted) {
      _goHome();
    } else {
      setState(() => _checking = false);
    }
  }

  Future<bool> requestBlePermissions() async {
      List<Permission> permissionsToRequest = [];
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        permissionsToRequest.addAll([
          Permission.location,
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
        ]);
        if (androidInfo.version.sdkInt >= 33) {
          permissionsToRequest.add(Permission.nearbyWifiDevices);
        }
      } else if (Platform.isIOS) {
        permissionsToRequest.addAll([Permission.bluetooth, Permission.locationWhenInUse]);
      }

      Map<Permission, PermissionStatus> statuses = await permissionsToRequest.request();
      return statuses.values.every((status) => status.isGranted);
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: _checking
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('İzinler kontrol ediliyor...'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.shield_outlined, color: Colors.amber, size: 60),
                  const SizedBox(height: 16),
                  const Text('İzinler Gerekli', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  const Text('Uygulamanın çalışması için Konum ve Bluetooth izinleri zorunludur.', textAlign: TextAlign.center,),
                  const SizedBox(height: 20),
                  ElevatedButton(onPressed: _checkAndRequest, child: const Text('İzinleri Tekrar İste')),
                  TextButton(onPressed: openAppSettings, child: const Text('Ayarları Manuel Aç')),
                ],
              ),
        ),
      ),
    );
  }
}

//******************************************************************
// BLE TEST ANA EKRANI (ARTIK ESKİ HİÇBİR KOD İÇERMİYOR)
//******************************************************************
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BleService _ble = BleService();
  final List<DiscoveredDeviceSimple> _devices = [];
  late String _localId;
  late String _localName = "Yükleniyor..."; // Başlangıç değeri atadık
  
  // Eski projedeki StreamSubscription yerine, native'den gelen olayları dinleyeceğiz.
  StreamSubscription? _nativeEventSub;

  bool _running = false;

  @override
  void initState() {
    super.initState();
    _initLocalId();
    _listenForNativeEvents();
  }

  @override
  void dispose() {
    _ble.dispose();
    _nativeEventSub?.cancel();
    super.dispose();
  }

  Future<void> _initLocalId() async {
    final prefs = await SharedPreferences.getInstance();
    _localId = prefs.getString('device_id') ?? const uuid_gen.Uuid().v4();
    await prefs.setString('device_id', _localId);
    _localName = 'HayatKöprüsü-${_localId.substring(0, 4)}';
    if(mounted) setState(() {});
  }
  
  void _listenForNativeEvents() {
    const EventChannel _events = EventChannel('com.example.multipeer/events');
    _nativeEventSub = _events.receiveBroadcastStream().listen((dynamic event) {
        if(!mounted) return;
        final evt = Map<String, dynamic>.from(event as Map);
        final type = evt['event'] as String? ?? '';

        if (type == 'peerFound') {
           final device = DiscoveredDeviceSimple(
               id: evt['peerId'] as String,
               name: evt['displayName'] as String,
               rssi: evt['rssi'] as int,
           );
           setState(() {
             final idx = _devices.indexWhere((d) => d.id == device.id);
             if (idx >= 0) {
                _devices[idx] = device; // Var olanı güncelle
             } else { 
                _devices.add(device); // Yeni ekle
             }
             // Sinyal gücüne göre sırala (en güçlü en üstte)
             _devices.sort((a, b) => b.rssi.compareTo(a.rssi));
           });
        }
    });
  }

  void _startAll() async {
    if (_running) return;
    setState(() { _running = true; _devices.clear(); });
    // Önce Reklam Başlat
    await _ble.startAdvertising(deviceId: _localId, deviceName: _localName);
    // Kısa bir gecikme
    await Future.delayed(const Duration(milliseconds: 300));
    // Sonra Taramayı Başlat
    await _ble.startScanning();
  }

  void _stopAll() async {
    if (!_running) return;
    await _ble.stopScanning();
    await _ble.stopAdvertising();
    setState(() { _running = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(title: Text(_localName)),
        body: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                       Text('Durum: ${_running ? "Keşif Aktif" : "Beklemede"}', 
                            style: TextStyle(color: _running ? Colors.green.shade600 : Colors.red.shade600, fontWeight: FontWeight.bold)
                       ),
                       const SizedBox(height: 12),
                       Row(
                         mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                         children: [
                           ElevatedButton.icon(
                            icon: const Icon(Icons.sensors),
                            label: const Text('Keşfi Başlat'),
                            onPressed: _running ? null : _startAll,
                           ),
                           ElevatedButton.icon(
                            icon: const Icon(Icons.sensors_off),
                            label: const Text('Durdur'),
                            onPressed: _running ? _stopAll : null,
                           ),
                         ],
                       ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 24, thickness: 1),
              Text('Bulunan Cihazlar (${_devices.length})', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Expanded(
                child: _running && _devices.isEmpty 
                ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 10), Text("Cihazlar aranıyor...")],))
                : !_running && _devices.isEmpty
                ? const Center(child: Text("Keşfi başlatın."))
                : ListView.builder(
                  itemCount: _devices.length,
                  itemBuilder: (ctx, i) {
                    final dev = _devices[i];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.bluetooth_searching),
                        title: Text(dev.name),
                        subtitle: Text(dev.id),
                        trailing: Text("${dev.rssi} dBm", style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    );
                  },
                ),
              )
            ],
          ),
        ));
  }
}