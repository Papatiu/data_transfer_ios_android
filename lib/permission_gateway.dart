import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

final MethodChannel _nativeChannel = const MethodChannel('com.example.multipeer/methods');

class PermissionGateway extends StatefulWidget {
  const PermissionGateway({super.key});
  @override
  State<PermissionGateway> createState() => _PermissionGatewayState();
}

class _PermissionGatewayState extends State<PermissionGateway> {
  bool _isChecking = true;
  bool _nativePolling = false;

  @override
  void initState() {
    super.initState();
    // küçük delay ile başlat (UI hazır olsun)
    Future.delayed(Duration(milliseconds: 200), _handlePermissions);
  }

  // Helper: get native permission state snapshot (from AppDelegate)
  Future<Map<String, dynamic>> _getNativePermissions() async {
    try {
      final res = await _nativeChannel.invokeMethod('getNativePermissions');
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      debugPrint('getNativePermissions failed: $e');
    }
    return {};
  }

  // Helper: call native to instantiate CBCentralManager (this often triggers the system prompt)
  Future<void> _triggerNativeBluetoothRequest() async {
    try {
      await _nativeChannel.invokeMethod('requestBluetooth');
    } catch (e) {
      debugPrint('requestBluetooth native failed: $e');
    }
  }

  // Helper: call native to request location via CLLocationManager
  Future<void> _triggerNativeLocationRequest() async {
    try {
      await _nativeChannel.invokeMethod('requestLocationPermission');
    } catch (e) {
      debugPrint('requestLocationPermission native failed: $e');
    }
  }

  // Waits up to totalMs for native permissions to change (polling)
  Future<Map<String, dynamic>> _waitForNativePermissionChange({int totalMs = 2000, int intervalMs = 300}) async {
    final int loops = (totalMs / intervalMs).ceil();
    Map<String, dynamic> last = {};
    for (int i = 0; i < loops; i++) {
      last = await _getNativePermissions();
      if (last.isNotEmpty) {
        // if bluetooth is not notDetermined, we consider it updated
        final String bt = last['bluetooth']?.toString() ?? '';
        final String loc = last['location']?.toString() ?? '';
        if (!bt.toLowerCase().contains('rawvalue: 0') && !loc.toLowerCase().contains('rawvalue: 0')) {
          return last;
        }
      }
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
    return last;
  }

  Future<void> _handlePermissions() async {
    if (mounted) setState(() => _isChecking = true);

    if (Platform.isIOS) {
      // 1) get native snapshot
      final before = await _getNativePermissions();
      debugPrint('Native perms before: $before');

      // 2) instantiate CBCentralManager via native to prompt Bluetooth dialog (this is crucial)
      await _triggerNativeBluetoothRequest();
      // small delay & poll native state
      final polled1 = await _waitForNativePermissionChange(totalMs: 1500);
      debugPrint('Native perms after trigger (1): $polled1');

      // 3) Now ask permission_handler for bluetooth & location (this integrates with plugin state)
      final statuses = await [Permission.bluetooth, Permission.locationWhenInUse].request();
      statuses.forEach((p, s) => debugPrint('permission_handler: $p -> $s'));

      // 4) Also call native location request if needed (some devices need native flow)
      await _triggerNativeLocationRequest();
      final polled2 = await _waitForNativePermissionChange(totalMs: 1500);
      debugPrint('Native perms after trigger (2): $polled2');

      // 5) final check using both plugin and native
      final btStatus = await Permission.bluetooth.status;
      final locStatus = await Permission.locationWhenInUse.status;
      debugPrint('Final plugin statuses: bluetooth=$btStatus location=$locStatus');

      final nativeFinal = await _getNativePermissions();
      debugPrint('Native perms final: $nativeFinal');

      final bool bluetoothOk = btStatus.isGranted || nativeFinal['bluetooth']?.toString().toLowerCase().contains('authorized') == true || nativeFinal['bluetooth']?.toString().contains('rawValue: 3') == true;
      final bool locationOk = locStatus.isGranted || !(nativeFinal['location']?.toString().toLowerCase().contains('rawvalue: 0') ?? true);

      if (bluetoothOk && locationOk) {
        // devam et
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/home'); // veya pushReplacement HomePage
        return;
      } else {
        // Eğer permission_handler izin isteğini gösteremiyorsa (permanentlyDenied), kullanıcıyı ayarlara gönder
        if (btStatus.isPermanentlyDenied || locStatus.isPermanentlyDenied) {
          if (!mounted) return;
          final open = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('İzinler Gerekiyor'),
              content: const Text('Bluetooth veya Konum izinleri kalıcı olarak reddedilmiş. Lütfen Ayarlar → Uygulamalar → Bu Uygulama bölümünden izinleri açın.'),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('İptal')),
                TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Ayarlar')),
              ],
            ),
          );
          if (open == true) openAppSettings();
        } else {
          // normal reddedilmiş — kullanıcıya tekrar deneme seçeneği ver
          if (mounted) setState(() => _isChecking = false);
        }
      }
    } else if (Platform.isAndroid) {
      // Android flow (unchanged)
      final statuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ].request();

      final allGranted = statuses.values.every((s) => s.isGranted);
      if (allGranted) {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/home');
      } else {
        if (mounted) setState(() => _isChecking = false);
      }
    } else {
      // other platforms: allow
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    // small UI: reuse your existing permission UI
    return Scaffold(
      body: Center(
        child: _isChecking ? const CircularProgressIndicator() : Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('İzinler gerekli.'),
            ElevatedButton(onPressed: _handlePermissions, child: const Text('Tekrar Dene')),
            TextButton(onPressed: () => openAppSettings(), child: const Text('Ayarlar')),
          ],
        ),
      ),
    );
  }
}
