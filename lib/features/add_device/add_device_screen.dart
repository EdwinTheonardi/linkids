// lib/features/add_device/add_device_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:linkids/core/constants/app_colors.dart';
import 'package:linkids/core/models/kid_device.dart';
import 'package:linkids/core/services/ble_service.dart';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen>
    with SingleTickerProviderStateMixin {
  final BleService _ble = BleService.instance;

  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  bool _isConnecting = false; // true saat sedang proses connect ke device

  StreamSubscription? _scanSubscription;
  StreamSubscription? _isScanningSubscription;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Listen ke status scanning dari BleService
    _isScanningSubscription = _ble.isScanningStream.listen((scanning) {
      if (!mounted) return;
      setState(() => _isScanning = scanning);
      if (scanning) {
        _pulseController.repeat(reverse: true);
      } else {
        _pulseController.stop();
        _pulseController.reset();
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _ble.stopScan();
    super.dispose();
  }

  // ── Scan ─────────────────────────────────────────────────────────────────
  Future<void> _startScan() async {
    // Minta permission dulu sebelum scan
    final granted = await _ble.requestPermissions();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Bluetooth & location permission required."),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }

    setState(() => _scanResults = []);

    _scanSubscription?.cancel();
    _scanSubscription = _ble.startScan().listen((results) {
      if (!mounted) return;
      setState(() => _scanResults = results);
    });
  }

  Future<void> _stopScan() async {
    await _ble.stopScan();
    _scanSubscription?.cancel();
  }

  // ── Dialog konfirmasi connect ─────────────────────────────────────────────
  void _showConnectDialog(ScanResult scanResult) {
    final deviceName = _getDeviceName(scanResult);

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: AppColors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.10),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.bluetooth_rounded,
                    size: 28, color: AppColors.primary),
              ),
              const SizedBox(height: 16),
              const Text(
                "Connect Device?",
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textDark,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 8),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                    height: 1.5,
                  ),
                  children: [
                    const TextSpan(text: "Connect to "),
                    TextSpan(
                      text: deviceName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark,
                      ),
                    ),
                    const TextSpan(text: " and add it to your monitored devices?"),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // MAC address
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.device_hub_rounded,
                        size: 15, color: AppColors.textMuted),
                    const SizedBox(width: 8),
                    Text(
                      scanResult.device.remoteId.str,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _connectToDevice(scanResult, deviceName);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  child: const Text("Connect"),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textMuted,
                    side: BorderSide(color: AppColors.textMuted.withOpacity(0.3)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  child: const Text("Cancel"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Connect ke device via BleService ─────────────────────────────────────
  Future<void> _connectToDevice(ScanResult scanResult, String name) async {
    setState(() => _isConnecting = true);

    final kidDevice = await _ble.connectDevice(
      scanResult: scanResult,
      kidName: name,
    );

    if (!mounted) return;
    setState(() => _isConnecting = false);

    if (kidDevice != null) {
      // Kembalikan KidDevice ke HomeScreen via Navigator.pop
      Navigator.of(context).pop(kidDevice);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to connect. Please try again."),
          backgroundColor: AppColors.danger,
        ),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      // Overlay loading saat connecting
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                _buildScanArea(),
                const SizedBox(height: 24),
                if (_scanResults.isNotEmpty || _isScanning)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _isScanning ? "Scanning nearby..." : "Devices Found",
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark,
                            letterSpacing: -0.3,
                          ),
                        ),
                        if (_scanResults.isNotEmpty)
                          Text(
                            "${_scanResults.length} device${_scanResults.length != 1 ? 's' : ''}",
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: _isScanning && _scanResults.isEmpty
                      ? _buildScanningPlaceholder()
                      : _scanResults.isEmpty
                          ? _buildIdleState()
                          : _buildDeviceList(),
                ),
              ],
            ),
          ),

          // ── Loading overlay saat connecting ──────────────────────────
          if (_isConnecting)
            Container(
              color: Colors.black.withOpacity(0.4),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      "Connecting...",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 20, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 20, color: AppColors.primary),
          ),
          const SizedBox(width: 4),
          const Text(
            "Add Device",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.textDark,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }

  // ── Scan Area ─────────────────────────────────────────────────────────────
  Widget _buildScanArea() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_isScanning)
                      Container(
                        width: 90 * _pulseAnimation.value,
                        height: 90 * _pulseAnimation.value,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primaryLight.withOpacity(
                              0.08 * (2 - _pulseAnimation.value)),
                        ),
                      ),
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isScanning
                            ? AppColors.primary
                            : AppColors.primary.withOpacity(0.08),
                      ),
                      child: Icon(
                        Icons.bluetooth_searching_rounded,
                        size: 34,
                        color: _isScanning ? Colors.white : AppColors.primary,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            Text(
              _isScanning ? "Scanning for nearby devices..." : "Ready to scan",
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _isScanning ? AppColors.primary : AppColors.textMuted,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _isScanning
                  ? "Make sure your ESP32-C3 is powered on"
                  : "Press the button below to find nearby\nLinkids hardware devices",
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SizedBox(
                width: double.infinity,
                child: _isScanning
                    ? OutlinedButton.icon(
                        onPressed: _stopScan,
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: const Text("Stop Scan"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          side: BorderSide(
                              color: AppColors.danger.withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      )
                    : ElevatedButton.icon(
                        onPressed: _startScan,
                        icon: const Icon(Icons.search_rounded, size: 18),
                        label: const Text("Start Scan"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Idle state ────────────────────────────────────────────────────────────
  Widget _buildIdleState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_disabled_rounded,
              size: 48, color: AppColors.textMuted.withOpacity(0.3)),
          const SizedBox(height: 12),
          const Text(
            "No results yet",
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            "Press Start Scan to search\nfor nearby devices",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── Skeleton loader saat scanning ─────────────────────────────────────────
  Widget _buildScanningPlaceholder() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, __) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: AppColors.background,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 120, height: 12,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 80, height: 10,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Device list ───────────────────────────────────────────────────────────
  Widget _buildDeviceList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      itemCount: _scanResults.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) =>
          _buildDeviceCard(_scanResults[index]),
    );
  }

  // Ambil nama device dari semua sumber yang tersedia
  // flutter_blue_plus punya 3 sumber nama, dicek berurutan:
  //   1. advertisementData.localName  → nama dari scan response firmware
  //   2. device.platformName          → nama yang di-cache Android
  //   3. Generate dari MAC address    → "Linkids-xx" (2 digit terakhir MAC)
  String _getDeviceName(ScanResult scanResult) {
    if (scanResult.advertisementData.localName.isNotEmpty) {
      return scanResult.advertisementData.localName;
    }
    if (scanResult.device.platformName.isNotEmpty) {
      return scanResult.device.platformName;
    }
    // Fallback: generate nama dari 2 byte terakhir MAC address
    // Contoh: MAC "AA:BB:CC:DD:EE:01" → "Linkids-EE01"
    final mac = scanResult.device.remoteId.str;
    final parts = mac.split(':');
    if (parts.length >= 2) {
      final suffix = parts[parts.length - 2] + parts[parts.length - 1];
      return 'Linkids-$suffix';
    }
    return 'Linkids Device';
  }

  Widget _buildDeviceCard(ScanResult scanResult) {
    final name = _getDeviceName(scanResult);

    return GestureDetector(
      onTap: () => _showConnectDialog(scanResult),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.bluetooth_rounded,
                  size: 22, color: AppColors.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDark,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textMuted, size: 22),
          ],
        ),
      ),
    );
  }
}