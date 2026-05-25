// lib/core/services/ble_service.dart
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:linkids/core/models/kid_device.dart';
import 'package:linkids/core/services/device_repository.dart';

// ═════════════════════════════════════════════════════════════════════════════
// KONVERSI RSSI → JARAK
// ═════════════════════════════════════════════════════════════════════════════
DeviceDistance rssiToDistance(int rssiAverage) {
  if (rssiAverage >= AlarmConfig.rssiVeryClose) return DeviceDistance.veryClose;
  if (rssiAverage >= AlarmConfig.rssiClose) return DeviceDistance.close;
  if (rssiAverage >= AlarmConfig.rssiFar) return DeviceDistance.far;
  return DeviceDistance.outOfRange;
}

double rssiToSignalStrength(int rssi) {
  const int minRssi = -100;
  const int maxRssi = -40;
  return ((rssi - minRssi) / (maxRssi - minRssi)).clamp(0.0, 1.0);
}

// ═════════════════════════════════════════════════════════════════════════════
// ALARM THRESHOLD CONFIG
// ═════════════════════════════════════════════════════════════════════════════
class AlarmConfig {
  static const int rssiVeryClose = -60;
  static const int rssiClose = -75;
  static const int rssiFar = -85;

  static const int stage1ThresholdMs = 1000;
  static const int stage2ThresholdMs = 4000;

  // Interval antar percobaan reconnect saat device disconnect
  static const int reconnectIntervalSec = 15;
}

// ── UUID ──────────────────────────────────────────────────────────────────────
class BleUuid {
  static const String service = '06afa479-0127-4b87-b1eb-bfa3006b8eac';
  static const String alarmCharacteristic =
      '92b4e4b4-17ae-4acb-b852-53a9a7f6c29f';
  static const String statusCharacteristic =
      'f5c2f358-9362-4c86-b248-48049225dfa4';
}

// ── Alert Stage ───────────────────────────────────────────────────────────────
enum AlertStage { none, stage1, stage2 }

// ═════════════════════════════════════════════════════════════════════════════
// SIGNAL PROCESSOR
// ═════════════════════════════════════════════════════════════════════════════
class _SignalProcessor {
  static const int windowSize = 15;
  static const int minSamplesNeeded = 8;

  final List<int> _window = [];
  DateTime? _dangerEnteredAt;
  AlertStage _currentStage = AlertStage.none;
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
    final bool rssiInDanger =
        distance == DeviceDistance.far || distance == DeviceDistance.outOfRange;

    if (rssiInDanger) {
      if (_isStage2Locked) return;

      _dangerEnteredAt ??= DateTime.now();
      final int durationMs =
          DateTime.now().difference(_dangerEnteredAt!).inMilliseconds;

      AlertStage newStage = AlertStage.none;
      if (durationMs >= AlarmConfig.stage2ThresholdMs) {
        newStage = AlertStage.stage2;
      } else if (durationMs >= AlarmConfig.stage1ThresholdMs) {
        newStage = AlertStage.stage1;
      }

      if (newStage.index > _currentStage.index) {
        _currentStage = newStage;
        if (_currentStage == AlertStage.stage2) _isStage2Locked = true;
        onStageChanged(_currentStage);
      }
    } else {
      _dangerEnteredAt = null;
      if (_isStage2Locked) return;
      if (_currentStage == AlertStage.stage1) {
        _currentStage = AlertStage.none;
        onStageChanged(AlertStage.none);
      }
    }
  }

  void forceReset() {
    _window.clear();
    _dangerEnteredAt = null;
    _isStage2Locked = false;
    if (_currentStage != AlertStage.none) {
      _currentStage = AlertStage.none;
      onStageChanged(AlertStage.none);
    }
  }

  // Reset internal state tanpa emit event —
  // dipakai saat disconnect agar window lama tidak ikut terbawa ke sesi baru
  void reset() {
    _window.clear();
    _dangerEnteredAt = null;
    _isStage2Locked = false;
    _currentStage = AlertStage.none;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// BLE DEVICE CONNECTION
// ═════════════════════════════════════════════════════════════════════════════
class BleDeviceConnection {
  final BluetoothDevice bleDevice;

  // true  → disconnect disengaja (user remove / app close)
  //         tidak trigger alarm, tidak auto-reconnect
  // false → disconnect tidak disengaja (sinyal putus, baterai habis)
  //         trigger alarm stage2, mulai auto-reconnect loop
  bool intentionalDisconnect = false;

  BluetoothCharacteristic? _alarmCharacteristic;
  BluetoothCharacteristic? _statusCharacteristic;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _heartbeatSubscription;
  Timer? _rssiTimer;

  // ── Auto-reconnect ────────────────────────────────────────────────────────
  Timer? _reconnectTimer;
  bool _isReconnecting = false;

  late final _SignalProcessor _processor;

  final _deviceStreamController = StreamController<KidDevice>.broadcast();
  Stream<KidDevice> get deviceStream => _deviceStreamController.stream;

  KidDevice _currentDevice;
  KidDevice get currentDevice => _currentDevice;

  final void Function(String deviceId, AlertStage stage) onAlertStageChanged;

  // Callback ke BleService — BleService yang handle scan & connect
  final Future<bool> Function(BleDeviceConnection conn) onRequestReconnect;

  BleDeviceConnection({
    required this.bleDevice,
    required KidDevice initialDevice,
    required this.onAlertStageChanged,
    required this.onRequestReconnect,
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
              _heartbeatSubscription = _statusCharacteristic!.onValueReceived
                  .listen((_) {});
            }
          }
        }
      }

      _connectionSubscription = bleDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnect();
        }
      });

      _startRssiPolling();
    } catch (e) {
      print('[BLE] initialize error: $e');
    }
  }

  // ── Handle disconnect ────────────────────────────────────────────────────
  void _handleDisconnect() {
    _stopRssiPolling();
    _processor.reset();
    _updateKidDevice(isConnected: false);

    if (intentionalDisconnect) return;

    // Trigger alarm bahaya karena disconnect tidak disengaja
    onAlertStageChanged(_currentDevice.id, AlertStage.stage2);

    // Mulai retry reconnect setiap reconnectIntervalSec detik
    _startReconnectLoop();
  }

  // ── Auto-reconnect loop ──────────────────────────────────────────────────
  //
  // Loop berjalan terus di background selama:
  //   - intentionalDisconnect == false
  //   - device belum kembali connected
  //
  // Loop berhenti otomatis saat:
  //   [A] onReconnectSuccess() dipanggil → connected kembali
  //   [B] dispose() dipanggil → user remove device atau app close
  void _startReconnectLoop() {
    if (_reconnectTimer != null) return; // sudah ada loop, skip

    print('[BLE] reconnect loop started for ${_currentDevice.id}');

    _reconnectTimer = Timer.periodic(
      Duration(seconds: AlarmConfig.reconnectIntervalSec),
      (_) async {
        if (intentionalDisconnect) {
          _stopReconnectLoop();
          return;
        }
        if (_currentDevice.isConnected) {
          _stopReconnectLoop();
          return;
        }
        if (_isReconnecting) return; // percobaan sebelumnya masih jalan

        _isReconnecting = true;
        final success = await onRequestReconnect(this);
        _isReconnecting = false;

        if (success) {
          _stopReconnectLoop();
        }
        // Gagal → timer akan coba lagi di interval berikutnya
      },
    );
  }

  void _stopReconnectLoop() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // ── Restart reconnect loop — dipanggil saat Bluetooth HP dinyalakan ulang ─
  //
  // Saat BT dimatikan lalu dinyalakan ulang, reconnect loop yang sebelumnya
  // berjalan sudah berhenti karena scan gagal. Fungsi ini memulai loop baru.
  void restartReconnectLoop() {
    if (intentionalDisconnect) return;
    if (_currentDevice.isConnected) return;
    if (_reconnectTimer != null) return; // sudah ada loop, skip

    print(
      '[BLE] restarting reconnect loop for ${_currentDevice.id} after BT on',
    );
    _startReconnectLoop();
  }

  // ── Pause reconnect loop — dipanggil saat Bluetooth HP dimatikan ──────────
  //
  // Tidak ada gunanya scan saat BT mati — pause dulu, nanti restart
  // saat BT dinyalakan kembali via restartReconnectLoop().
  void pauseReconnectLoop() {
    print('[BLE] pausing reconnect loop for ${_currentDevice.id} — BT off');
    _stopReconnectLoop();
    _isReconnecting = false;
  }

  // ── Dipanggil BleService setelah reconnect berhasil ─────────────────────
  //
  // Re-wire semua BLE subscription yang sudah invalid setelah koneksi putus.
  // Alarm stage2 TIDAK di-reset di sini — user tetap harus tap Dismiss.
  Future<void> onReconnectSuccess() async {
    _stopReconnectLoop();
    _isReconnecting = false;
    _processor.reset(); // buang window RSSI lama, mulai fresh

    try {
      // Re-discover services karena ini koneksi BLE baru
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
              await _heartbeatSubscription?.cancel();
              _heartbeatSubscription = _statusCharacteristic!.onValueReceived
                  .listen((_) {});
            }
          }
        }
      }

      // Re-wire connection state listener
      await _connectionSubscription?.cancel();
      _connectionSubscription = bleDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnect();
        }
      });

      _updateKidDevice(isConnected: true);
      _startRssiPolling();

      print('[BLE] re-initialized after reconnect for ${_currentDevice.id}');
    } catch (e) {
      print('[BLE] re-initialize error: $e');
      // Gagal re-init → anggap disconnect lagi → loop akan coba reconnect lagi
      _handleDisconnect();
    }
  }

  // ── RSSI polling ─────────────────────────────────────────────────────────
  void _startRssiPolling() {
    _stopRssiPolling();
    _rssiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      try {
        final int rawRssi = await bleDevice.readRssi();
        final int? averageRssi = _processor.addSample(rawRssi);
        if (averageRssi != null) {
          _updateKidDevice(rssi: averageRssi);
        }
      } catch (_) {
        // Gagal baca RSSI — connectionState listener yang akan handle disconnect
      }
    });
  }

  void _stopRssiPolling() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  void _updateKidDevice({int? rssi, bool? isConnected}) {
    final bool connected = isConnected ?? true;
    final DeviceDistance distance =
        (rssi != null && connected)
            ? rssiToDistance(rssi)
            : DeviceDistance.outOfRange;
    final double signalStrength =
        (rssi != null && connected) ? rssiToSignalStrength(rssi) : 0.0;

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

  void dismissStage2() => _processor.forceReset();

  Future<void> triggerAlarm() async => _writeAlarm(true);
  Future<void> stopAlarm() async => _writeAlarm(false);

  Future<void> _writeAlarm(bool active) async {
    if (_alarmCharacteristic == null) return;
    try {
      await _alarmCharacteristic!.write([
        active ? 0x01 : 0x00,
      ], withoutResponse: false);
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
    _stopRssiPolling();
    _stopReconnectLoop();
    await _heartbeatSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _processor.reset();
    if (!_deviceStreamController.isClosed) {
      await _deviceStreamController.close();
    }
    try {
      await bleDevice.disconnect();
    } catch (_) {}
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// BLE SERVICE — SINGLETON
// ═════════════════════════════════════════════════════════════════════════════
class BleService {
  // ── Constructor — langsung pasang Bluetooth state listener ────────────────
  BleService._() {
    _listenBluetoothState();
  }
  static final BleService instance = BleService._();

  final Map<String, BleDeviceConnection> _connections = {};
  final Map<String, String> _pendingDevices = {};

  // ── Bluetooth state subscription ──────────────────────────────────────────
  // Dipakai untuk mendeteksi saat Bluetooth HP dimatikan lalu dinyalakan ulang
  StreamSubscription? _bluetoothStateSubscription;

  final _devicesController = StreamController<List<KidDevice>>.broadcast();
  final _alertStageController =
      StreamController<(String, AlertStage)>.broadcast();

  Stream<List<KidDevice>> get devicesStream => _devicesController.stream;
  Stream<(String, AlertStage)> get alertStageStream =>
      _alertStageController.stream;

  List<KidDevice> get allDevices {
    final connected = _connections.values.map((c) => c.currentDevice).toList();
    final connectedIds = connected.map((d) => d.id).toSet();
    final pending =
        _pendingDevices.entries
            .where((e) => !connectedIds.contains(e.key))
            .map(
              (e) => KidDevice(
                id: e.key,
                name: e.value,
                isConnected: false,
                distance: DeviceDistance.outOfRange,
                signalStrength: 0.0,
              ),
            )
            .toList();
    return [...connected, ...pending];
  }

  // ── Listener state Bluetooth HP ──────────────────────────────────────────
  //
  // Mendeteksi dua kondisi:
  //   [ON]  → Bluetooth baru dinyalakan ulang setelah dimatikan
  //           Semua reconnect loop yang berhenti karena BT mati perlu distart ulang
  //   [OFF] → Bluetooth dimatikan
  //           Pause semua reconnect loop — tidak ada gunanya scan saat BT mati
  void _listenBluetoothState() {
    _bluetoothStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        print('[BLE] Bluetooth turned ON — trigger reconnect for all devices');
        _onBluetoothTurnedOn();
      } else if (state == BluetoothAdapterState.off) {
        print('[BLE] Bluetooth turned OFF — pausing all reconnect loops');
        _onBluetoothTurnedOff();
      }
    });
  }

  // ── Handler: Bluetooth dinyalakan ulang ──────────────────────────────────
  Future<void> _onBluetoothTurnedOn() async {
    // Tunggu sebentar agar Bluetooth adapter stabil sebelum mulai scan
    await Future.delayed(const Duration(seconds: 2));

    // Restart reconnect loop untuk semua connection yang sedang disconnect
    for (final conn in _connections.values) {
      if (!conn.currentDevice.isConnected && !conn.intentionalDisconnect) {
        conn.restartReconnectLoop();
      }
    }

    // Untuk pending devices yang belum pernah connect, jalankan autoReconnectAll
    if (_pendingDevices.isNotEmpty) {
      final pendingIds = _pendingDevices.keys.toSet();
      // Filter hanya yang belum ada di _connections
      final notYetConnected =
          pendingIds.where((id) => !_connections.containsKey(id)).toSet();
      if (notYetConnected.isNotEmpty) {
        print(
          '[BLE] autoReconnectAll for ${notYetConnected.length} pending device(s)',
        );
        _autoReconnectAll(notYetConnected);
      }
    }
  }

  // ── Handler: Bluetooth dimatikan ─────────────────────────────────────────
  void _onBluetoothTurnedOff() {
    // Pause semua reconnect loop — BT mati, scan tidak akan berhasil
    for (final conn in _connections.values) {
      conn.pauseReconnectLoop();
    }
  }

  // ── Restore saved devices saat app dibuka ────────────────────────────────
  Future<void> restoreDevices() async {
    final saved = await DeviceRepository.instance.loadAll();
    if (saved.isEmpty) return;

    for (final d in saved) {
      _pendingDevices[d.id] = d.name;
    }
    _emitAllDevices();

    _autoReconnectAll(saved.map((d) => d.id).toSet());
  }

  Future<void> _autoReconnectAll(Set<String> targetIds) async {
    if (targetIds.isEmpty) return;

    final granted = await requestPermissions();
    if (!granted) return;

    final remaining = Set<String>.from(targetIds);
    const timeout = Duration(seconds: 20);

    StreamSubscription? scanSub;
    scanSub = FlutterBluePlus.onScanResults.listen((results) async {
      for (final result in results) {
        final mac = result.device.remoteId.str;
        if (!remaining.contains(mac)) continue;
        remaining.remove(mac);
        final name = _pendingDevices[mac] ?? 'Linkids Device';
        await _connectAndRegister(scanResult: result, deviceName: name);
        if (remaining.isEmpty) {
          await FlutterBluePlus.stopScan();
          scanSub?.cancel();
        }
      }
    });

    await FlutterBluePlus.startScan(
      timeout: timeout,
      withServices: [Guid(BleUuid.service)],
    );

    await Future.delayed(timeout + const Duration(seconds: 1));
    scanSub.cancel();
  }

  // ── Reconnect satu device — dipanggil dari _reconnectTimer tiap device ───
  //
  // Scan singkat untuk cari MAC address spesifik, lalu connect.
  // Return true jika berhasil, false jika tidak ketemu / gagal connect.
  Future<bool> _performReconnect(BleDeviceConnection conn) async {
    final mac = conn.currentDevice.id;

    // Cek apakah sudah ada scan lain yang berjalan
    final isAlreadyScanning = await FlutterBluePlus.isScanning.first;

    const scanDuration = Duration(seconds: 8);
    final completer = Completer<ScanResult?>();

    final scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId.str == mac && !completer.isCompleted) {
          completer.complete(r);
          break;
        }
      }
    });

    // Mulai scan baru hanya jika tidak ada scan yang sedang berjalan
    if (!isAlreadyScanning) {
      await FlutterBluePlus.startScan(
        timeout: scanDuration,
        withServices: [Guid(BleUuid.service)],
      );
    }

    // Tunggu device ketemu atau timeout
    final targetResult = await completer.future.timeout(
      scanDuration + const Duration(seconds: 1),
      onTimeout: () => null,
    );

    scanSub.cancel();
    if (!isAlreadyScanning) {
      await FlutterBluePlus.stopScan().catchError((_) {});
    }

    if (targetResult == null) {
      print('[BLE] device $mac not found in scan');
      return false;
    }

    // Device ketemu → coba connect
    try {
      await conn.bleDevice.connect(timeout: const Duration(seconds: 10));
      await conn.onReconnectSuccess();
      _emitAllDevices();
      return true;
    } catch (e) {
      print('[BLE] reconnect connect/init error for $mac: $e');
      return false;
    }
  }

  // ── Helper: connect + buat BleDeviceConnection + daftarkan ───────────────
  Future<void> _connectAndRegister({
    required ScanResult scanResult,
    required String deviceName,
  }) async {
    final mac = scanResult.device.remoteId.str;
    if (_connections.containsKey(mac)) return;

    try {
      await scanResult.device.connect(timeout: const Duration(seconds: 10));

      final initialDevice = KidDevice(
        id: mac,
        name: deviceName,
        isConnected: true,
        distance: rssiToDistance(scanResult.rssi),
        signalStrength: rssiToSignalStrength(scanResult.rssi),
      );

      final connection = BleDeviceConnection(
        bleDevice: scanResult.device,
        initialDevice: initialDevice,
        onAlertStageChanged: _onAlertStageChanged,
        onRequestReconnect: _performReconnect,
      );

      await connection.initialize();
      _connections[mac] = connection;
      _pendingDevices.remove(mac);

      connection.deviceStream.listen((_) => _emitAllDevices());
      _emitAllDevices();
    } catch (e) {
      print('[BLE] _connectAndRegister error for $mac: $e');
    }
  }

  Future<bool> requestPermissions() async {
    final statuses =
        await [
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

  // ── Connect device baru dari AddDeviceScreen ──────────────────────────────
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
        onRequestReconnect: _performReconnect,
      );

      await connection.initialize();
      _connections[id] = connection;
      _pendingDevices.remove(id);

      connection.deviceStream.listen((_) => _emitAllDevices());
      _emitAllDevices();

      await DeviceRepository.instance.save(SavedDevice(id: id, name: kidName));

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

    if (stage == AlertStage.stage2) conn.triggerAlarm();

    _emitAllDevices();
  }

  void dismissStage2(String deviceId) {
    _connections[deviceId]?.dismissStage2();
    _emitAllDevices();
  }

  Future<void> renameDevice(String deviceId, String newName) async {
    final conn = _connections[deviceId];
    if (conn != null) {
      conn._currentDevice = conn._currentDevice.copyWith(name: newName);
      conn._deviceStreamController.add(conn._currentDevice);
    }
    if (_pendingDevices.containsKey(deviceId)) {
      _pendingDevices[deviceId] = newName;
    }
    await DeviceRepository.instance.updateName(deviceId, newName);
    _emitAllDevices();
  }

  Future<void> disconnectDevice(String id) async {
    final conn = _connections.remove(id);
    if (conn != null) {
      conn.intentionalDisconnect = true;
      await conn.dispose();
    }
    _pendingDevices.remove(id);
    await DeviceRepository.instance.remove(id);
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
    await _bluetoothStateSubscription?.cancel(); // cleanup BT state listener
    for (final conn in _connections.values) {
      await conn.dispose();
    }
    _connections.clear();
    _pendingDevices.clear();
    await _devicesController.close();
    await _alertStageController.close();
  }
}
