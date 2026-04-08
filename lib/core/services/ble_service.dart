// lib/core/services/ble_service.dart
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:linkids/core/models/kid_device.dart';

// ═════════════════════════════════════════════════════════════════════════════
// KONVERSI RSSI → JARAK
// ═════════════════════════════════════════════════════════════════════════════
DeviceDistance rssiToDistance(int rssiAverage) {
  if (rssiAverage >= AlarmConfig.rssiVeryClose) return DeviceDistance.veryClose;
  if (rssiAverage >= AlarmConfig.rssiClose)     return DeviceDistance.close;
  if (rssiAverage >= AlarmConfig.rssiFar)       return DeviceDistance.far;
  return DeviceDistance.outOfRange;
}

double rssiToSignalStrength(int rssi) {
  const int minRssi = -100;
  const int maxRssi = -40;
  return ((rssi - minRssi) / (maxRssi - minRssi)).clamp(0.0, 1.0);
}

// ═════════════════════════════════════════════════════════════════════════════
// ALARM THRESHOLD CONFIG
// Semua threshold di satu tempat — ubah di sini setelah uji lapangan
// ═════════════════════════════════════════════════════════════════════════════
class AlarmConfig {
  // ── RSSI Threshold ────────────────────────────────────────────────────────
  static const int rssiVeryClose = -60; // ≤ ~1m  → safe
  static const int rssiClose     = -75; // ~1–3m  → caution
  static const int rssiFar       = -85; // ~3–5m  → danger
  // < rssiFar = outOfRange → danger

  // ── Hysteresis Threshold ──────────────────────────────────────────────────
  static const int stage1ThresholdMs = 1000; // 1 detik di danger → Stage 1
  static const int stage2ThresholdMs = 4000; // 4 detik di danger → Stage 2

  // ── PRR Threshold ─────────────────────────────────────────────────────────
  // Alarm hanya bunyi jika RSSI danger DAN PRR di bawah threshold
}

// ── UUID ──────────────────────────────────────────────────────────────────────
class BleUuid {
  static const String service              = '06afa479-0127-4b87-b1eb-bfa3006b8eac';
  static const String alarmCharacteristic  = '92b4e4b4-17ae-4acb-b852-53a9a7f6c29f';
  static const String statusCharacteristic = 'f5c2f358-9362-4c86-b248-48049225dfa4';
}

// ── Alert Stage ───────────────────────────────────────────────────────────────
enum AlertStage {
  none,   // Zona safe/caution — tidak ada aksi
  stage1, // Danger ≥1 detik kontinu → 1x getar ringan di HP
  stage2, // Danger ≥4 detik kontinu → getar terus + popup + notif + buzzer hardware
}

// ═════════════════════════════════════════════════════════════════════════════
// SIGNAL PROCESSOR
// [1] Sliding Window Moving Average — smoothing RSSI
// [2] Multistage Hysteresis — butuh durasi tertentu di danger sebelum naik stage
// [3] Stage 2 lock — stage 2 tidak bisa turun otomatis, hanya via forceReset()
// ═════════════════════════════════════════════════════════════════════════════
class _SignalProcessor {

  // ── Config ────────────────────────────────────────────────────────────────
  static const int windowSize       = 15; // 15 × 200ms = 3 detik
  static const int minSamplesNeeded = 8;

  // ── State ─────────────────────────────────────────────────────────────────
  final List<int> _window = [];
  DateTime? _dangerEnteredAt;
  AlertStage _currentStage = AlertStage.none;

  // Flag: stage 2 hanya bisa turun via forceReset(), tidak otomatis
  bool _isStage2Locked = false;

  AlertStage get currentStage => _currentStage;

  final void Function(AlertStage stage) onStageChanged;

  _SignalProcessor({required this.onStageChanged});

  int? addSample(int rawRssi) {
    _window.add(rawRssi);
    if (_window.length > windowSize) _window.removeAt(0);
    if (_window.length < minSamplesNeeded) return null;

    final int average = _window.reduce((a, b) => a + b) ~/ _window.length;
    _runHysteresis(average);
    return average;
  }

  void _runHysteresis(int averageRssi) {
    final DeviceDistance distance = rssiToDistance(averageRssi);
    final bool rssiInDanger = distance == DeviceDistance.far ||
                              distance == DeviceDistance.outOfRange;

    if (rssiInDanger) {
      // ── Di zona danger ────────────────────────────────────────────────────

      // Jika stage 2 sudah locked, tidak perlu proses lebih lanjut
      // Stage 2 sudah aktif dan hanya bisa di-reset via forceReset()
      if (_isStage2Locked) return;

      _dangerEnteredAt ??= DateTime.now();
      final int durationMs = DateTime.now()
          .difference(_dangerEnteredAt!)
          .inMilliseconds;

      AlertStage newStage = AlertStage.none;

      if (durationMs >= AlarmConfig.stage2ThresholdMs) {
        newStage = AlertStage.stage2;
      } else if (durationMs >= AlarmConfig.stage1ThresholdMs) {
        newStage = AlertStage.stage1;
      }

      // Stage hanya boleh naik (none→stage1→stage2)
      if (newStage.index > _currentStage.index) {
        _currentStage = newStage;
        if (_currentStage == AlertStage.stage2) {
          _isStage2Locked = true; // kunci stage 2 — hanya turun via forceReset()
        }
        onStageChanged(_currentStage);
      }

    } else {
      // ── Kembali ke zona aman ──────────────────────────────────────────────

      // Reset timer danger
      _dangerEnteredAt = null;

      // Stage 2 locked → tidak emit none otomatis
      // Hanya forceReset() yang bisa menurunkan stage 2
      if (_isStage2Locked) return;

      // Stage 1 bisa turun otomatis ke none
      if (_currentStage == AlertStage.stage1) {
        _currentStage = AlertStage.none;
        onStageChanged(AlertStage.none);
      }
    }
  }

  // Dipanggil saat user tap Dismiss di popup
  // Reset semua state sehingga stage bisa naik lagi dari nol
  void forceReset() {
    _window.clear();
    _dangerEnteredAt = null;
    _isStage2Locked = false;
    if (_currentStage != AlertStage.none) {
      _currentStage = AlertStage.none;
      onStageChanged(AlertStage.none);
    }
  }

  // Dipanggil saat device disconnect
  void reset() {
    _window.clear();
    _dangerEnteredAt = null;
    _isStage2Locked = false;
    if (_currentStage != AlertStage.none) {
      _currentStage = AlertStage.none;
      onStageChanged(AlertStage.none);
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// BLE DEVICE CONNECTION
// Satu instance per device yang terhubung
// ═════════════════════════════════════════════════════════════════════════════
class BleDeviceConnection {
  final BluetoothDevice bleDevice;
  bool intentionalDisconnect = false;

  BluetoothCharacteristic? _alarmCharacteristic;
  BluetoothCharacteristic? _statusCharacteristic;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _heartbeatSubscription;
  Timer? _rssiTimer;

  late final _SignalProcessor _processor;

  final _deviceStreamController = StreamController<KidDevice>.broadcast();
  Stream<KidDevice> get deviceStream => _deviceStreamController.stream;

  KidDevice _currentDevice;
  KidDevice get currentDevice => _currentDevice;

  final void Function(String deviceId, AlertStage stage) onAlertStageChanged;

  BleDeviceConnection({
    required this.bleDevice,
    required KidDevice initialDevice,
    required this.onAlertStageChanged,
  }) : _currentDevice = initialDevice {
    _processor = _SignalProcessor(
      onStageChanged: (stage) => onAlertStageChanged(_currentDevice.id, stage),
    );
  }

  Future<void> initialize() async {
    try {
      final services = await bleDevice.discoverServices();
      for (final service in services) {
        if (service.uuid.toString() == BleUuid.service) {
          for (final char in service.characteristics) {
            if (char.uuid.toString() == BleUuid.alarmCharacteristic) {
              _alarmCharacteristic = char;
            }
            if (char.uuid.toString() == BleUuid.statusCharacteristic) {
              _statusCharacteristic = char;
              await _statusCharacteristic!.setNotifyValue(true);
              // Subscribe notify untuk keepalive koneksi
              _heartbeatSubscription = _statusCharacteristic!
                  .onValueReceived
                  .listen((_) {});
            }
          }
        }
      }

      // Deteksi disconnect hardware
      _connectionSubscription = bleDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _processor.reset();
          _updateKidDevice(isConnected: false);
          if (!intentionalDisconnect) {
            // Disconnect tiba-tiba → langsung stage 2
            onAlertStageChanged(_currentDevice.id, AlertStage.stage2);
          }
        }
      });

      // Polling RSSI setiap 200ms
      _rssiTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) async {
          try {
            final int rawRssi = await bleDevice.readRssi();
            final int? averageRssi = _processor.addSample(rawRssi);
            if (averageRssi != null) {
              _updateKidDevice(rssi: averageRssi);
            }
          } catch (_) {
            // Gagal baca RSSI → kemungkinan disconnect
            _processor.reset();
            _updateKidDevice(isConnected: false);
            if (!intentionalDisconnect) {
              onAlertStageChanged(_currentDevice.id, AlertStage.stage2);
            }
          }
        },
      );
    } catch (e) {
      print('[BLE] initialize error: $e');
    }
  }

  void _updateKidDevice({int? rssi, bool? isConnected}) {
    final bool connected = isConnected ?? true;
    final DeviceDistance distance = (rssi != null && connected)
        ? rssiToDistance(rssi)
        : DeviceDistance.outOfRange;
    final double signalStrength = (rssi != null && connected)
        ? rssiToSignalStrength(rssi)
        : 0.0;

    _currentDevice = _currentDevice.copyWith(
      isConnected: connected,
      distance: distance,
      signalStrength: signalStrength,
      rssiAverage: rssi,
    );

    if (!_deviceStreamController.isClosed) {
      _deviceStreamController.add(_currentDevice);
    }
  }

  // Dipanggil saat user dismiss popup stage 2
  // Reset processor sehingga stage bisa naik lagi dari nol
  // TIDAK mematikan hardware buzzer — itu lewat tombol terpisah di card
  void dismissStage2() {
    _processor.forceReset();
  }

  Future<void> triggerAlarm() async => _writeAlarm(true);
  Future<void> stopAlarm()    async => _writeAlarm(false);

  Future<void> _writeAlarm(bool active) async {
    if (_alarmCharacteristic == null) return;
    try {
      await _alarmCharacteristic!.write(
        [active ? 0x01 : 0x00],
        withoutResponse: false,
      );
      _currentDevice = _currentDevice.copyWith(isAlarmActive: active);
      if (!_deviceStreamController.isClosed) {
        _deviceStreamController.add(_currentDevice);
      }
    } catch (e) {
      print('[BLE] write alarm error: $e');
    }
  }

  Future<void> dispose() async {
    intentionalDisconnect = true;
    _rssiTimer?.cancel();
    _heartbeatSubscription?.cancel();
    _connectionSubscription?.cancel();
    _processor.reset();
    if (!_deviceStreamController.isClosed) {
      await _deviceStreamController.close();
    }
    try { await bleDevice.disconnect(); } catch (_) {}
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// BLE SERVICE — SINGLETON
// ═════════════════════════════════════════════════════════════════════════════
class BleService {
  BleService._();
  static final BleService instance = BleService._();

  final Map<String, BleDeviceConnection> _connections = {};

  final _devicesController    = StreamController<List<KidDevice>>.broadcast();
  final _alertStageController = StreamController<(String, AlertStage)>.broadcast();

  Stream<List<KidDevice>>      get devicesStream    => _devicesController.stream;
  Stream<(String, AlertStage)> get alertStageStream => _alertStageController.stream;

  List<KidDevice> get allDevices =>
      _connections.values.map((c) => c.currentDevice).toList();

  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  Stream<List<ScanResult>> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) {
    FlutterBluePlus.startScan(
      timeout: timeout,
      withServices: [Guid(BleUuid.service)],
    );
    return FlutterBluePlus.scanResults;
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();
  Stream<bool> get isScanningStream => FlutterBluePlus.isScanning;

  Future<KidDevice?> connectDevice({
    required ScanResult scanResult,
    required String kidName,
  }) async {
    final BluetoothDevice bleDevice = scanResult.device;
    final String id = bleDevice.remoteId.str;

    if (_connections.containsKey(id)) return _connections[id]!.currentDevice;

    try {
      await bleDevice.connect(timeout: const Duration(seconds: 10));

      final KidDevice initialDevice = KidDevice(
        id: id,
        name: kidName,
        isConnected: true,
        distance: rssiToDistance(scanResult.rssi),
        signalStrength: rssiToSignalStrength(scanResult.rssi),
      );

      final BleDeviceConnection connection = BleDeviceConnection(
        bleDevice: bleDevice,
        initialDevice: initialDevice,
        onAlertStageChanged: _onAlertStageChanged,
      );

      await connection.initialize();
      _connections[id] = connection;

      connection.deviceStream.listen((_) => _emitAllDevices());
      _emitAllDevices();

      return connection.currentDevice;
    } catch (e) {
      print('[BLE] connect error: $e');
      return null;
    }
  }

  void _onAlertStageChanged(String deviceId, AlertStage stage) {
    if (!_alertStageController.isClosed) {
      _alertStageController.add((deviceId, stage));
    }

    final BleDeviceConnection? conn = _connections[deviceId];
    if (conn == null) return;

    // Stage 2 → nyalakan buzzer hardware otomatis
    if (stage == AlertStage.stage2) {
      conn.triggerAlarm();
    }
    // Stage 1 dan none → tidak ada aksi ke hardware
    // Hardware buzzer hanya dimatikan via tombol di card

    _emitAllDevices();
  }

  // Dipanggil saat user dismiss popup stage 2
  // Reset processor agar stage bisa naik lagi dari nol jika masih dalam bahaya
  // TIDAK mematikan hardware buzzer
  void dismissStage2(String deviceId) {
    _connections[deviceId]?.dismissStage2();
    _emitAllDevices();
  }

  Future<void> disconnectDevice(String id) async {
    final conn = _connections.remove(id);
    if (conn != null) {
      conn.intentionalDisconnect = true;
      await conn.dispose();
    }
    _emitAllDevices();
  }

  Future<void> triggerAlarm(String id) async {
    await _connections[id]?.triggerAlarm();
    _emitAllDevices();
  }

  Future<void> stopAlarm(String id) async {
    await _connections[id]?.stopAlarm();
    _emitAllDevices();
  }

  void _emitAllDevices() {
    if (!_devicesController.isClosed) {
      _devicesController.add(allDevices);
    }
  }

  Future<void> disposeAll() async {
    for (final conn in _connections.values) {
      await conn.dispose();
    }
    _connections.clear();
    await _devicesController.close();
    await _alertStageController.close();
  }
}