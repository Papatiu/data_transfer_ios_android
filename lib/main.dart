// lib/main.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'multipeer_service.dart';
import 'mesh/mesh_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PermissionGateway(),
    );
  }
}

class PermissionGateway extends StatefulWidget {
  const PermissionGateway({super.key});
  @override
  State<PermissionGateway> createState() => _PermissionGatewayState();
}

class _PermissionGatewayState extends State<PermissionGateway> {
  static const MethodChannel _nativeChannel = MethodChannel('com.example.multipeer/methods');

  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    // ensure runs after frame; avoids timing race with platform channels
    WidgetsBinding.instance.addPostFrameCallback((_) => _handlePermissions());
  }

  Future<Map<String, dynamic>?> _getNativePermissionStatus() async {
    try {
      final res = await _nativeChannel.invokeMethod('getNativePermissions');
      if (res is Map) return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('getNativePermissionStatus failed: $e');
    }
    return null;
  }

  Future<void> _handlePermissions() async {
    if (!mounted) return;
    setState(() => _isChecking = true);

    final nativeBefore = await _getNativePermissionStatus();
    debugPrint('Native perms before: $nativeBefore');

    if (Platform.isAndroid) {
      await _handleAndroid();
    } else if (Platform.isIOS) {
      await _handleIos(nativeBefore: nativeBefore);
    } else {
      _goHome();
    }

    if (!mounted) return;
    setState(() => _isChecking = false);
  }

  Future<void> _handleAndroid() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final perms = <Permission>[
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ];
    if (androidInfo.version.sdkInt >= 33) {
      perms.add(Permission.nearbyWifiDevices);
    }

    final statuses = await perms.request();
    debugPrint('Android statuses: $statuses');

    final allGranted = statuses.values.every((s) => s.isGranted);
    if (allGranted) {
      _goHome();
      return;
    }

    final anyPermanent = statuses.values.any((s) => s.isPermanentlyDenied);
    if (anyPermanent && mounted) {
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('İzin gerekiyor'),
          content: const Text('Bazı izinler kalıcı olarak reddedilmiş. Lütfen Ayarlar > Uygulama bölümünden gerekli izinleri verin.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tamam')),
            TextButton(onPressed: openAppSettings, child: const Text('Ayarlar')),
          ],
        ),
      );
    } else {
      // attempt native fallbacks if needed
      try {
        await _nativeChannel.invokeMethod('requestBluetooth');
      } catch (e) {}
    }
  }

  Future<void> _handleIos({Map<String, dynamic>? nativeBefore}) async {
    final statuses = await [Permission.bluetooth, Permission.locationWhenInUse].request();
    debugPrint('iOS statuses: $statuses');

    // If permission_handler didn't resolve, trigger native prompts
    if (statuses[Permission.bluetooth]?.isDenied == true || statuses[Permission.bluetooth]?.isPermanentlyDenied == true) {
      try {
        await _nativeChannel.invokeMethod('requestBluetooth');
        await Future.delayed(const Duration(milliseconds: 700));
      } catch (e) {
        debugPrint('requestBluetooth native failed: $e');
      }
    }

    // trigger a short advertise to ensure local network prompt if needed
    try {
      await _nativeChannel.invokeMethod('triggerLocalNetwork', {'displayName': 'iOS Device'});
      await Future.delayed(const Duration(milliseconds: 700));
    } catch (e) {
      debugPrint('triggerLocalNetwork failed: $e');
    }

    if (statuses[Permission.locationWhenInUse]?.isDenied == true) {
      try {
        await _nativeChannel.invokeMethod('requestLocationPermission');
        await Future.delayed(const Duration(milliseconds: 700));
      } catch (e) {
        debugPrint('requestLocationPermission failed: $e');
      }
    }

    final finalNative = await _getNativePermissionStatus();
    debugPrint('Native perms final: $finalNative');

    final cb = finalNative?['bluetooth']?.toString() ?? '';
    final loc = finalNative?['location']?.toString() ?? '';

    final bluetoothOk = cb.toLowerCase().contains('enabled') || statuses[Permission.bluetooth]?.isGranted == true;
    final locationOk = loc.toLowerCase().contains('granted') || statuses[Permission.locationWhenInUse]?.isGranted == true;

    if (bluetoothOk && locationOk) {
      _goHome();
    } else {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('İzin Gerekli'),
          content: const Text('Bluetooth veya konum izinleri yok. Lütfen Ayarlar > (Uygulama) bölümünden gerekli izinleri verin.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tamam')),
            TextButton(onPressed: openAppSettings, child: const Text('Ayarlar')),
          ],
        ),
      );
    }
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _isChecking
            ? const Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('İzinler kontrol ediliyor...')])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Uygulamanın çalışması için izinler gereklidir.'),
                const SizedBox(height: 8),
                ElevatedButton(onPressed: _handlePermissions, child: const Text('Tekrar İste')),
                TextButton(onPressed: openAppSettings, child: const Text('Ayarları Aç')),
              ]),
      ),
    );
  }
}

// ---------------- HomePage ----------------
class Peer {
  final String id;
  final String name;
  Peer({required this.id, required this.name});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<Peer> discoveredPeers = [];
  String? connectedPeerId;
  final TextEditingController _messageController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<Map<String, dynamic>>? _meshSub;

  String? _localId;
  String? _localName;

  bool _initializing = true;
  bool _running = false;
  final Completer<void> _initCompleter = Completer<void>();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // 1) persistent id
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('mesh_device_id');
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString('mesh_device_id', id);
    }
    _localId = id;
    _localName = 'Device-${_localId!.substring(0, 6)}';

    // 2) Mesh init if present
    try {
      await MeshService().init(deviceId: _localId!, deviceName: _localName!);
      _meshSub = MeshService().onMessage.listen((msg) {
        // optional
      });
    } catch (e) {
      debugPrint('Mesh init error: $e');
    }

    // 3) start listening events
    _startListening();

    // mark ready
    if (!_initCompleter.isCompleted) _initCompleter.complete();
    setState(() {
      _initializing = false;
    });
  }

  void _startListening() {
    _eventSub = MultipeerService.events.listen((evt) {
      final type = evt['event'] as String? ?? '';
      if (type == 'peerFound') {
        final id = evt['peerId'] as String? ?? '';
        final name = evt['displayName'] as String? ?? id;
        if (!discoveredPeers.any((p) => p.id == id)) {
          setState(() => discoveredPeers.add(Peer(id: id, name: name)));
        }
      } else if (type == 'peerLost') {
        final id = evt['peerId'] as String? ?? '';
        setState(() => discoveredPeers.removeWhere((p) => p.id == id));
      } else if (type == 'connectionState') {
        final state = evt['state'] as String? ?? '';
        final id = evt['peerId'] as String?;
        if (state == 'connected' && id != null) setState(() => connectedPeerId = id);
        if (state == 'notConnected' && id != null && connectedPeerId == id) setState(() => connectedPeerId = null);
      } else if (type == 'dataReceived') {
        final List<dynamic>? arr = evt['data'] as List<dynamic>?;
        if (arr != null) {
          final msg = String.fromCharCodes(arr.cast<int>());
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gelen: $msg')));
        }
      } else if (type == 'error') {
        final m = evt['message'] as String? ?? 'Hata';
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
      }
    }, onError: (e) {
      debugPrint('Event stream error: $e');
    });
  }

  Future<void> _ensureInit() async {
    if (!_initCompleter.isCompleted) {
      try {
        await _initCompleter.future.timeout(const Duration(seconds: 5));
      } catch (_) {
        // timeout - but ensure default values exist
      }
    }
    _localId ??= const Uuid().v4();
    _localName ??= 'Device-${_localId!.substring(0, 6)}';
  }

  Future<void> _startAdvertiseOnly() async {
    await _ensureInit();
    if (_running) return;
    try {
      await MultipeerService.startAdvertising(displayName: _localName, serviceType: 'mpconn');
      setState(() => _running = true);
    } catch (e) {
      _showStatus('Advertise error: $e');
    }
  }

  Future<void> _startBrowseOnly() async {
    await _ensureInit();
    if (_running) return;
    try {
      await MultipeerService.startBrowsing(displayName: _localName, serviceType: 'mpconn');
      setState(() => _running = true);
    } catch (e) {
      _showStatus('Browsing error: $e');
    }
  }

  Future<void> _startBoth() async {
    await _ensureInit();
    if (_running) return;
    try {
      await MultipeerService.startAdvertising(displayName: _localName, serviceType: 'mpconn');
      await Future.delayed(const Duration(milliseconds: 300));
      await MultipeerService.startBrowsing(displayName: _localName, serviceType: 'mpconn');
      setState(() => _running = true);
    } catch (e) {
      _showStatus('Start error: $e');
    }
  }

  Future<void> _stopAll() async {
    try {
      await MultipeerService.stop();
    } catch (e) {
      debugPrint('stop error: $e');
    }
    _eventSub?.cancel();
    setState(() {
      _running = false;
      discoveredPeers.clear();
      connectedPeerId = null;
    });
  }

  void _invitePeer(Peer peer) {
    MultipeerService.invitePeer(peer.id).catchError((e) => _showStatus('Davet hatası: $e'));
  }

  Future<void> _sendMessage() async {
    final t = _messageController.text.trim();
    if (t.isEmpty) return;
    final bytes = Uint8List.fromList(t.codeUnits);
    try {
      await MultipeerService.sendData(bytes);
      _messageController.clear();
      _showStatus('Gönderildi');
    } catch (e) {
      _showStatus('Gönderme hatası: $e');
    }
  }

  void _showStatus(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _meshSub?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = !_initializing;
    return Scaffold(
      appBar: AppBar(title: const Text('P2P — Multipeer + Mesh')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(children: [
          Row(children: [
            ElevatedButton(onPressed: ready && !_running ? _startAdvertiseOnly : null, child: const Text('Görünür Ol (Host)')),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: ready && !_running ? _startBrowseOnly : null, child: const Text('Cihaz Ara (Guest)')),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: ready && !_running ? _startBoth : null, child: const Text('Başlat (Advertise+Scan)')),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _running ? _stopAll : null, child: const Text('Durdur')),
          ]),
          const SizedBox(height: 12),
          Text('Cihazınız: ${_localName ?? '...'}'),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: discoveredPeers.length,
              itemBuilder: (ctx, i) {
                final dev = discoveredPeers[i];
                return ListTile(
                  title: Text(dev.name),
                  subtitle: Text(dev.id),
                  trailing: ElevatedButton(onPressed: () => _invitePeer(dev), child: const Text('Bağlan')),
                );
              },
            ),
          ),
          if (_running && connectedPeerId != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(child: TextField(controller: _messageController, decoration: const InputDecoration(labelText: 'Mesaj'))),
                IconButton(icon: const Icon(Icons.send), onPressed: _sendMessage),
              ]),
            ),
        ]),
      ),
    );
  }
}
