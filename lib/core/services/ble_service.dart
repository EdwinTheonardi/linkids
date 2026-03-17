// lib/core/services/ble_service.dart
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:linkids/core/models/kid_device.dart';

// ═════════════════════════════════════════════════════════════════════════════
// KONVERSI RSSI → JARAK
// Input : nilai RSSI rata-rata hasil sliding window (dalam dBm, nilai negatif)
// Output: enum DeviceDistance
// Threshold dikalibrasi setelah pengujian lapangan dengan ESP32-C3
// ═════════════════════════════════════════════════════════════════════════════
DeviceDistance rssiToDistance(int rssiAverage) {
  if (rssiAverage >= -60) return DeviceDistance.veryClose; // < ~1m
  if (rssiAverage >= -75) return DeviceDistance.close;     // ~1–3m
  if (rssiAverage >= -90) return DeviceDistance.far;        // ~3–8m
  return DeviceDistance.outOfRange;                         // > ~8m
}

// Normalisasi RSSI ke 0.0–1.0 untuk progress bar sinyal di UI
double rssiToSignalStrength(int rssi) {
  const int minRssi = -100;
  const int maxRssi = -40;
  return ((rssi - minRssi) / (maxRssi - minRssi)).clamp(0.0, 1.0);
}

// ── UUID ──────────────────────────────────────────────────────────────────────
class BleUuid {
  static const String service              = '06afa479-0127-4b87-b1eb-bfa3006b8eac';
  static const String alarmCharacteristic  = '92b4e4b4-17ae-4acb-b852-53a9a7f6c29f';
  static const String statusCharacteristic = 'f5c2f358-9362-4c86-b248-48049225dfa4';
}

// ── Alert Stage ───────────────────────────────────────────────────────────────
enum AlertStage {
  none,   // Zona aman/waspada
  stage1, // Danger ≥1 detik → vibrasi ringan di HP
  stage2, // Danger ≥2 detik → vibrasi kuat + bunyi HP + buzzer ESP32
}

// ═════════════════════════════════════════════════════════════════════════════
// SIGNAL PROCESSOR
// Menggabungkan dua mekanisme anti-false-alarm:
//
// [1] SLIDING WINDOW MOVING AVERAGE
//     - ESP32 mengirim BLE packet setiap 100ms
//     - HP membaca RSSI tiap 100ms dan menyimpannya ke buffer
//     - Buffer berukuran 10 → merepresentasikan 1 detik data terakhir
//     - Setiap ada data baru: data terlama dibuang, data baru masuk
//     - Rata-rata dihitung dari semua data di buffer
//     - Rata-rata inilah yang dipakai untuk klasifikasi zona
//     - Efek: lonjakan RSSI sesaat (akibat sinyal menabrak benda) tidak
//       langsung mengubah zona, karena hanya berkontribusi 1/10 dari average
//
//     Contoh (window size = 10):
//     t=0  buffer: [-55,-57,-56,-58,-54,-56,-57,-55,-56,-57] avg=-56 → safe
//     t=1  buffer: [-57,-56,-58,-54,-56,-57,-55,-56,-57,-85] avg=-59 → safe
//     t=2  buffer: [-56,-58,-54,-56,-57,-55,-56,-57,-85,-83] avg=-62 → close
//     → Butuh beberapa iterasi sebelum rata-rata benar-benar mencerminkan
//       perubahan jarak, bukan hanya lonjakan sesaat
//
// [2] MULTISTAGE TIME-BASED HYSTERESIS
//     - Rata-rata RSSI masuk zona danger → mulai hitung durasi
//     - Durasi ≥1 detik kontinu → naik ke Stage 1
//     - Durasi ≥2 detik kontinu → naik ke Stage 2
//     - Jika sinyal kembali ke safe/caution sebelum threshold → durasi direset
//     - Stage tidak bisa turun selama masih di zona danger
//     - Efek: sinyal yang masuk danger sesaat (<1 detik) tidak trigger alarm
// ═════════════════════════════════════════════════════════════════════════════
class _SignalProcessor {

  // ── [1] Sliding Window Config ─────────────────────────────────────────────
  static const int windowSize       = 10; // 10 sampel × 100ms = 1 detik
  static const int minSamplesNeeded = 5;  // minimum sampel sebelum mulai hitung

  // ── [2] Hysteresis Config ─────────────────────────────────────────────────
  static const int stage1ThresholdMs = 1000; // 1 detik di danger → Stage 1
  static const int stage2ThresholdMs = 2000; // 2 detik di danger → Stage 2

  // ── Internal State ────────────────────────────────────────────────────────
  final List<int> _window = []; // buffer sliding window, maks windowSize item
  DateTime? _dangerEnteredAt;   // waktu pertama kali masuk zona danger
  AlertStage _currentStage = AlertStage.none;

  AlertStage get currentStage => _currentStage;

  final void Function(AlertStage stage) onStageChanged;
  _SignalProcessor({required this.onStageChanged});

  // ── Proses satu sampel RSSI baru ─────────────────────────────────────────
  // Dipanggil setiap 100ms oleh polling timer di BleDeviceConnection
  // Mengembalikan RSSI rata-rata (null = buffer belum cukup)
  int? addSample(int rawRssi) {

    // ── LANGKAH 1: Masukkan sampel baru ke ujung kanan window ──────────────
    _window.add(rawRssi);

    // ── LANGKAH 2: Buang sampel terlama (ujung kiri) jika window penuh ─────
    // Inilah mekanisme "sliding" — window selalu berisi N data TERBARU
    if (_window.length > windowSize) {
      _window.removeAt(0); // hapus data paling lama
    }

    // ── LANGKAH 3: Hitung rata-rata jika sampel sudah cukup ────────────────
    if (_window.length < minSamplesNeeded) {
      return null; // tunggu sampel lebih banyak sebelum mulai klasifikasi
    }

    // Moving average = jumlah semua nilai di window / jumlah item
    final int sum = _window.reduce((a, b) => a + b);
    final int average = sum ~/ _window.length;

    // ── LANGKAH 4: Klasifikasi zona dari rata-rata ──────────────────────────
    // Penting: klasifikasi pakai RATA-RATA, bukan raw RSSI
    _runHysteresis(average);

    return average;
  }

  // ── Jalankan mekanisme hysteresis berdasarkan rata-rata RSSI ─────────────
  void _runHysteresis(int averageRssi) {
    final DeviceDistance distance = rssiToDistance(averageRssi);

    // Tentukan apakah saat ini di zona danger
    final bool inDanger = distance == DeviceDistance.far ||
                          distance == DeviceDistance.outOfRange;

    if (inDanger) {
      // ── MASUK / BERTAHAN DI ZONA DANGER ──────────────────────────────────

      // Catat waktu pertama kali masuk danger (hanya sekali, tidak di-reset
      // selama masih terus di danger)
      _dangerEnteredAt ??= DateTime.now();

      // Hitung berapa lama sudah berada di zona danger secara kontinu
      final int durationMs = DateTime.now()
          .difference(_dangerEnteredAt!)
          .inMilliseconds;

      // Tentukan stage berdasarkan durasi
      AlertStage newStage;
      if (durationMs >= stage2ThresholdMs) {
        // ≥2 detik kontinu di danger → Stage 2
        newStage = AlertStage.stage2;
      } else if (durationMs >= stage1ThresholdMs) {
        // ≥1 detik kontinu di danger → Stage 1
        newStage = AlertStage.stage1;
      } else {
        // Belum cukup durasi → belum ada peringatan
        newStage = AlertStage.none;
      }

      // Stage hanya boleh naik (none→stage1→stage2), tidak boleh turun
      // selama masih di zona danger
      // Ini mencegah flapping stage saat RSSI berfluktuasi di batas threshold
      if (newStage.index > _currentStage.index) {
        _currentStage = newStage;
        onStageChanged(_currentStage);
      }

    } else {
      // ── KELUAR DARI ZONA DANGER (kembali ke safe/caution) ─────────────────

      // Reset semua state hysteresis
      _dangerEnteredAt = null;

      // Emit none hanya jika sebelumnya ada stage aktif
      // (tidak perlu emit none berulang-ulang saat memang sudah none)
      if (_currentStage != AlertStage.none) {
        _currentStage = AlertStage.none;
        onStageChanged(AlertStage.none);
      }
    }
  }

  // Reset semua state — dipanggil saat device disconnect
  void reset() {
    _window.clear();
    _dangerEnteredAt = null;
    if (_currentStage != AlertStage.none) {
      _currentStage = AlertStage.none;
      onStageChanged(AlertStage.none);
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// BLE DEVICE CONNECTION
// Merepresentasikan satu koneksi aktif ke satu ESP32-C3
// Tugasnya:
//   - Poll RSSI setiap 100ms
//   - Feed RSSI ke _SignalProcessor
//   - Update KidDevice state dan emit ke stream
//   - Kirim perintah alarm ke ESP32 via BLE write
// ═════════════════════════════════════════════════════════════════════════════
class BleDeviceConnection {
  final BluetoothDevice bleDevice;
  bool intentionalDisconnect = false;

  BluetoothCharacteristic? _alarmCharacteristic;
  StreamSubscription? _connectionSubscription;
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
      onStageChanged: (stage) {
        onAlertStageChanged(_currentDevice.id, stage);
      },
    );
  }

  Future<void> initialize() async {
    try {
      // Discover service dan characteristic di ESP32
      final services = await bleDevice.discoverServices();
      for (final service in services) {
        if (service.uuid.toString() == BleUuid.service) {
          for (final char in service.characteristics) {
            if (char.uuid.toString() == BleUuid.alarmCharacteristic) {
              _alarmCharacteristic = char;
            }
          }
        }
      }

      // Deteksi disconnect dari sisi hardware
      _connectionSubscription = bleDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          // Reset processor agar tidak ada sisa state dari koneksi sebelumnya
          _processor.reset();
          _updateKidDevice(isConnected: false);
          // Hanya trigger stage 2 jika disconnect tidak disengaja
          // (bukan karena user remove device dari app)
          if (!intentionalDisconnect) {
            onAlertStageChanged(_currentDevice.id, AlertStage.stage2);
          }
        }
      });

      // ── Polling RSSI setiap 100ms ─────────────────────────────────────────
      // Inilah sumber data untuk sliding window
      // readRssi() mengukur kekuatan sinyal yang DITERIMA HP dari ESP32
      _rssiTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) async {
          try {
            final int rawRssi = await bleDevice.readRssi();

            // Feed raw RSSI ke SignalProcessor
            // Processor akan:
            //   1. Tambahkan ke sliding window
            //   2. Hitung moving average
            //   3. Jalankan hysteresis
            //   4. Emit stage jika berubah
            final int? averageRssi = _processor.addSample(rawRssi);

            // Update UI hanya jika average sudah tersedia (buffer cukup)
            if (averageRssi != null) {
              _updateKidDevice(rssi: averageRssi);
            }
          } catch (_) {
            // readRssi gagal biasanya karena device sudah disconnect
            _processor.reset();
            _updateKidDevice(isConnected: false);
            if (!intentionalDisconnect) {
              onAlertStageChanged(_currentDevice.id, AlertStage.stage2);
            }
          }
        },
      );
    } catch (e) {
      // ignore: avoid_print
      print('[BLE] initialize error: $e');
    }
  }

  // Update state KidDevice dan emit ke stream (untuk update UI)
  void _updateKidDevice({int? rssi, bool? isConnected}) {
    final bool connected = isConnected ?? true;
    final DeviceDistance distance = (rssi != null && connected)
        ? rssiToDistance(rssi)   // gunakan rata-rata RSSI dari sliding window
        : DeviceDistance.outOfRange;
    final double signalStrength = (rssi != null && connected)
        ? rssiToSignalStrength(rssi)
        : 0.0;

    _currentDevice = _currentDevice.copyWith(
      isConnected: connected,
      distance: distance,
      signalStrength: signalStrength,
      rssiAverage: rssi, // DEBUG: simpan nilai average untuk ditampilkan di UI
    );

    if (!_deviceStreamController.isClosed) {
      _deviceStreamController.add(_currentDevice);
    }
  }

  // ── Kirim perintah alarm ke ESP32 via BLE write ───────────────────────────
  Future<void> triggerAlarm() async => _writeAlarm(true);
  Future<void> stopAlarm() async    => _writeAlarm(false);

  Future<void> _writeAlarm(bool active) async {
    if (_alarmCharacteristic == null) return;
    try {
      // 0x01 = nyalakan buzzer, 0x00 = matikan buzzer
      await _alarmCharacteristic!.write(
        [active ? 0x01 : 0x00],
        withoutResponse: false,
      );
      _currentDevice = _currentDevice.copyWith(isAlarmActive: active);
      if (!_deviceStreamController.isClosed) {
        _deviceStreamController.add(_currentDevice);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[BLE] write alarm error: $e');
    }
  }

  Future<void> dispose() async {
    _rssiTimer?.cancel();
    _processor.reset();
    await _connectionSubscription?.cancel();
    await _deviceStreamController.close();
    try { await bleDevice.disconnect(); } catch (_) {}
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// BLE SERVICE — SINGLETON
// Entry point utama yang dipakai oleh UI
// Mengelola semua BleDeviceConnection yang aktif
// ═════════════════════════════════════════════════════════════════════════════
class BleService {
  BleService._();
  static final BleService instance = BleService._();

  final Map<String, BleDeviceConnection> _connections = {};

  // Stream untuk update list device di HomeScreen
  final _devicesController    = StreamController<List<KidDevice>>.broadcast();
  // Stream untuk trigger vibrasi + dialog di HomeScreen
  final _alertStageController = StreamController<(String, AlertStage)>.broadcast();

  Stream<List<KidDevice>>        get devicesStream    => _devicesController.stream;
  Stream<(String, AlertStage)>   get alertStageStream => _alertStageController.stream;

  List<KidDevice> get allDevices =>
      _connections.values.map((c) => c.currentDevice).toList();

  // ── Request Permission ────────────────────────────────────────────────────
  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  // ── Scan ──────────────────────────────────────────────────────────────────
  Stream<List<ScanResult>> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) {
    FlutterBluePlus.startScan(
      timeout: timeout,
      // Filter pakai Service UUID — lebih reliable dari nama/keyword
      // Device yang advertise UUID ini dipastikan firmware Linkids
      withServices: [Guid(BleUuid.service)],
    );
    return FlutterBluePlus.scanResults;
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();
  Stream<bool> get isScanningStream => FlutterBluePlus.isScanning;

  // ── Connect ke device ─────────────────────────────────────────────────────
  Future<KidDevice?> connectDevice({
    required ScanResult scanResult,
    required String kidName,
  }) async {
    final BluetoothDevice bleDevice = scanResult.device;
    final String id = bleDevice.remoteId.str; // MAC address sebagai ID unik

    // Cegah double connect ke device yang sama
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

      // Setiap update dari device ini → emit seluruh list ke HomeScreen
      connection.deviceStream.listen((_) => _emitAllDevices());
      _emitAllDevices();

      return connection.currentDevice;
    } catch (e) {
      // ignore: avoid_print
      print('[BLE] connect error: $e');
      return null;
    }
  }

  // ── Dipanggil oleh _SignalProcessor via BleDeviceConnection ──────────────
  // Saat stage berubah: emit ke HomeScreen + aksi otomatis ke hardware
  void _onAlertStageChanged(String deviceId, AlertStage stage) {
    // Emit ke HomeScreen untuk trigger vibrasi + dialog
    if (!_alertStageController.isClosed) {
      _alertStageController.add((deviceId, stage));
    }

    final BleDeviceConnection? conn = _connections[deviceId];
    if (conn == null) return;

    if (stage == AlertStage.stage2) {
      // Stage 2 → aktifkan buzzer ESP32 secara otomatis via BLE write
      conn.triggerAlarm();
    } else if (stage == AlertStage.none) {
      // Kembali aman → matikan buzzer jika sedang aktif karena auto-trigger
      if (conn.currentDevice.isAlarmActive) {
        conn.stopAlarm();
      }
    }

    _emitAllDevices();
  }

  // ── Disconnect & hapus device ─────────────────────────────────────────────
  Future<void> disconnectDevice(String id) async {
    final conn = _connections.remove(id);
    await conn?.dispose();
    _emitAllDevices();
  }

  // ── Alarm manual dari tombol di UI ───────────────────────────────────────
  Future<void> triggerAlarm(String id) async {
    await _connections[id]?.triggerAlarm();
    _emitAllDevices();
  }

  Future<void> stopAlarm(String id) async {
    await _connections[id]?.stopAlarm();
    _emitAllDevices();
  }

  // ── Emit seluruh list KidDevice terbaru ke HomeScreen ────────────────────
  void _emitAllDevices() {
    if (!_devicesController.isClosed) {
      _devicesController.add(allDevices);
    }
  }

  // Panggil saat app ditutup
  Future<void> disposeAll() async {
    for (final conn in _connections.values) {
      await conn.dispose();
    }
    _connections.clear();
    await _devicesController.close();
    await _alertStageController.close();
  }
}