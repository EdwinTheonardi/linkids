// lib/features/home/home_screen.dart
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:linkids/core/constants/app_colors.dart';
import 'package:linkids/core/models/kid_device.dart';
import 'package:flutter/services.dart';
import 'package:linkids/core/services/ble_service.dart';
import 'package:linkids/features/add_device/add_device_screen.dart';
import 'package:linkids/core/services/background_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _ble = BleService.instance;

  List<KidDevice> devices = [];

  StreamSubscription? _devicesSubscription;
  StreamSubscription? _alertSubscription;
  final ScrollController _scrollController = ScrollController();

  // Track stage aktif per device
  final Map<String, AlertStage> _deviceStages = {};

  // Timer untuk continuous vibration saat stage2
  Timer? _vibrationTimer;
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Flag untuk mencegah double dialog
  bool _dangerDialogShowing = false;

  int get safeCount    => devices.where((d) => d.zone == AlarmZone.safe).length;
  int get cautionCount => devices.where((d) => d.zone == AlarmZone.caution).length;
  int get dangerCount  => devices.where((d) => d.zone == AlarmZone.danger).length;

  AlarmZone get worstZone {
    if (dangerCount > 0)  return AlarmZone.danger;
    if (cautionCount > 0) return AlarmZone.caution;
    return AlarmZone.safe;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {

    // Listen ke stream device dari BleService
    // Setiap ada update RSSI atau status, UI otomatis rebuild
    _devicesSubscription = _ble.devicesStream.listen((updatedDevices) {
      if (!mounted) return;
      setState(() => devices = updatedDevices);
    });

    // Listen ke alert stage — trigger vibrasi dan dialog sesuai stage
    _alertSubscription = _ble.alertStageStream.listen((event) {
      final (deviceId, stage) = event;
      if (!mounted) return;
      _handleAlertStage(deviceId, stage);
    });

    // Request permission notifikasi (Android 13+) lalu start foreground service
    await BackgroundService.instance.requestPermissions();
    BackgroundService.instance.start();
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _alertSubscription?.cancel();
    _vibrationTimer?.cancel();
    _audioPlayer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Aksi Alarm ────────────────────────────────────────────────────────────
  Future<void> _stopAlarm(KidDevice device) async {
    await _ble.stopAlarm(device.id);
  }

  Future<void> _triggerAlarm(KidDevice device) async {
    await _ble.triggerAlarm(device.id);
  }

  Future<void> _removeDevice(KidDevice device) async {
    await _ble.disconnectDevice(device.id);
    _deviceStages.remove(device.id);
    BackgroundService.instance.clearDeviceStage(device.id);
    // Stop vibration jika tidak ada lagi device yang stage2
    if (!_deviceStages.values.any((s) => s == AlertStage.stage2)) {
      _stopVibration();
      _stopAlarmSound();
    }
  }

  // ── Vibration control ────────────────────────────────────────────────────
  void _startContinuousVibration() {
    _vibrationTimer?.cancel();
    _vibrationTimer = Timer.periodic(
      const Duration(milliseconds: 600),
      (_) {
        if (mounted) HapticFeedback.heavyImpact();
      },
    );
  }

  void _stopVibration() {
    _vibrationTimer?.cancel();
    _vibrationTimer = null;
  }

  Future<void> _startAlarmSound() async {
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);
    await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
  }

  Future<void> _stopAlarmSound() async {
    await _audioPlayer.stop();
  }

  // ── Danger Dialog — hanya untuk stage 2 ──────────────────────────────────
  void _showDangerDialog(KidDevice device) {
    if (_dangerDialogShowing) return; // tidak tampilkan jika sudah ada dialog
    _dangerDialogShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DangerAlertDialog(
        dangerDevices: [device],
        onSeeDevice: (d) {
          Navigator.of(ctx).pop();
          _dangerDialogShowing = false;
          _scrollToDevice(d);
          _onDismissStage2(d.id);
        },
        onDismiss: () {
          Navigator.of(ctx).pop();
          _dangerDialogShowing = false;
          _onDismissStage2(device.id);
        },
      ),
    );
  }

  // Dipanggil saat user dismiss dialog stage 2
  void _onDismissStage2(String deviceId) {
    // Stop vibration, suara alarm, dan notifikasi di HP
    _stopVibration();
    _stopAlarmSound();
    BackgroundService.instance.dismissAlarmNotification();

    // Force reset stage2 ke none di BleService
    // Jika masih di danger zone, akan naik lagi ke stage1 setelah 1 detik
    // lalu ke stage2 setelah 3 detik lagi (no cooldown — by design)
    _ble.dismissStage2(deviceId);
    _deviceStages[deviceId] = AlertStage.none;
  }

  void _scrollToDevice(KidDevice device) {
    final index = devices.indexWhere((d) => d.id == device.id);
    if (index == -1) return;
    const double estimatedCardHeight = 214.0;
    _scrollController.animateTo(
      index * estimatedCardHeight,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  // ── Handle alert stage dari BleService ──────────────────────────────────
  void _handleAlertStage(String deviceId, AlertStage stage) {
    if (!mounted) return;

    // Cari device yang trigger
    final deviceList = devices.where((d) => d.id == deviceId).toList();
    if (deviceList.isEmpty) return;
    final device = deviceList.first;

    // Simpan stage terbaru device ini
    _deviceStages[deviceId] = stage;

    switch (stage) {
      case AlertStage.stage1:
        // Stage 1: getar ringan 1x saja
        // Tidak ada popup, tidak ada notifikasi, tidak ada buzzer hardware
        HapticFeedback.lightImpact();
        break;

      case AlertStage.stage2:
        // Stage 2: getar terus menerus + suara alarm + popup + notifikasi
        _startContinuousVibration();
        _startAlarmSound();
        // Kirim notifikasi ke background service
        BackgroundService.instance.notifyAlarmStage(stage, device.name, deviceId);
        // Tampilkan danger dialog
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showDangerDialog(device);
        });
        break;

      case AlertStage.none:
        // Kembali aman dari stage1 (otomatis)
        // Stage2 tidak akan sampai ke sini karena sudah di-lock
        // Hanya stop vibration jika tidak ada stage2 lain yang aktif
        if (!_deviceStages.values.any((s) => s == AlertStage.stage2)) {
          _stopVibration();
          _stopAlarmSound();
          BackgroundService.instance.notifyAlarmStage(stage, device.name, deviceId);
        }
        break;
    }
  }

  // ── Dialog konfirmasi remove ──────────────────────────────────────────────
  void _confirmRemoveDevice(KidDevice device) {
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
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.10),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.delete_rounded,
                    size: 28, color: AppColors.danger),
              ),
              const SizedBox(height: 16),
              const Text(
                "Remove Device?",
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
                    const TextSpan(text: "Are you sure you want to remove "),
                    TextSpan(
                      text: device.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark,
                      ),
                    ),
                    const TextSpan(text: "? This action cannot be undone."),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _removeDevice(device);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.danger,
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
                  child: const Text("Yes, Remove"),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textMuted,
                    side: BorderSide(
                        color: AppColors.textMuted.withOpacity(0.3)),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Column(
                children: [
                  _buildHeader(),
                  const SizedBox(height: 16),
                  _buildSummaryBanner(),
                  const SizedBox(height: 20),
                  _buildSectionTitle(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            Expanded(
              child: devices.isEmpty
                  ? _buildEmptyState()
                  : ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                      itemCount: devices.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 14),
                      itemBuilder: (context, index) =>
                          _buildKidCard(devices[index]),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          // AddDeviceScreen mengembalikan KidDevice jika connect berhasil
          // BleService sudah menyimpan koneksinya — HomeScreen cukup listen devicesStream
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
          );
          // Tidak perlu setState di sini —
          // devicesStream dari BleService akan otomatis emit KidDevice baru
        },
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          "Add Device",
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Image.asset("assets/images/logo-horizontal.png", width: 90),
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(Icons.notifications_none_rounded,
              color: AppColors.primary, size: 22),
        ),
      ],
    );
  }

  // ── Summary Banner ────────────────────────────────────────────────────────
  Widget _buildSummaryBanner() {
    // Jika belum ada device, tampilkan banner netral
    if (devices.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.textMuted.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.textMuted.withOpacity(0.2)),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 14, color: AppColors.textMuted),
            SizedBox(width: 10),
            Text(
              "No devices added yet.",
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    final zone = worstZone;
    final String message;
    if (zone == AlarmZone.safe) {
      message = "All ${devices.length} children are safe and nearby.";
    } else if (zone == AlarmZone.caution) {
      message = "$cautionCount child${cautionCount != 1 ? 'ren' : ''} moving away — stay alert!";
    } else {
      message = "$dangerCount child${dangerCount != 1 ? 'ren' : ''} out of safe zone — check now!";
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: zone.backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: zone.borderColor, width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              color: zone.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: zone.color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Section Title ─────────────────────────────────────────────────────────
  Widget _buildSectionTitle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          "Monitored Devices",
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.textDark,
            letterSpacing: -0.3,
          ),
        ),
        Text(
          "${devices.length} device${devices.length != 1 ? 's' : ''}",
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.textMuted,
          ),
        ),
      ],
    );
  }

  // ── Kid Card ──────────────────────────────────────────────────────────────
  Widget _buildKidCard(KidDevice device) {
    final zone = device.zone;
    final Border? cardBorder = zone == AlarmZone.safe
        ? null
        : Border.all(color: zone.borderColor, width: 1.2);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(18),
        border: cardBorder,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.07),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            // ── Top: Avatar + Name + Buttons ──────────────────────────
            Row(
              children: [
                Stack(
                  children: [
                    Container(
                      width: 52, height: 52,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person_rounded,
                          size: 28, color: AppColors.primary),
                    ),
                    Positioned(
                      right: 1, bottom: 1,
                      child: Container(
                        width: 13, height: 13,
                        decoration: BoxDecoration(
                          color: device.isConnected
                              ? AppColors.accent
                              : AppColors.danger,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textDark,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: zone.backgroundColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              zone.label,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: zone.color,
                              ),
                            ),
                          ),
                          if (device.isAlarmActive) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.danger.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.volume_up_rounded,
                                      size: 10, color: AppColors.danger),
                                  const SizedBox(width: 3),
                                  Text(
                                    "Alarm ON",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.danger,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(
                      onPressed: () { /* TODO: dialog rename */ },
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(68, 30),
                        foregroundColor: AppColors.primary,
                        side: const BorderSide(
                            color: AppColors.primary, width: 1.2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                      ),
                      child: const Text(
                        "Rename",
                        style: TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _confirmRemoveDevice(device),
                      child: Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(
                          color: AppColors.danger.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.delete_outline_rounded,
                            size: 17, color: AppColors.danger),
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 16),
            const Divider(height: 1, color: Color(0xFFEEF2F7)),
            const SizedBox(height: 14),

            // ── Row 1: Status chips ───────────────────────────────────
            Row(
              children: [
                _buildStatChip(
                  icon: Icons.bluetooth_rounded,
                  label: device.isConnected ? "Connected" : "Disconnected",
                  color: device.isConnected
                      ? AppColors.accent
                      : AppColors.textMuted,
                ),
                const SizedBox(width: 10),
                _buildStatChip(
                  icon: Icons.social_distance_rounded,
                  label: device.distance.label,
                  color: zone.color,
                ),
              ],
            ),

            // ── Row 2: Signal metrics (RSSI + PRR) ───────────────────
            if (device.rssiAverage != null || device.prrValue != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  // RSSI chip
                  if (device.rssiAverage != null) ...[
                    Expanded(
                      child: _buildMetricTile(
                        label: 'RSSI',
                        value: '${device.rssiAverage} dBm',
                        icon: Icons.wifi_tethering_rounded,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // PRR chip
                  if (device.prrValue != null)
                    Expanded(
                      child: _buildMetricTile(
                        label: 'PRR',
                        value: '${(device.prrValue! * 100).toStringAsFixed(0)}%',
                        icon: Icons.network_check_rounded,
                        color: device.prrValue! >= 0.8
                            ? AppColors.accent
                            : device.prrValue! >= 0.6
                                ? AppColors.warning
                                : AppColors.danger,
                      ),
                    ),
                ],
              ),
            ],

            // ── Bottom: Alarm Buttons ─────────────────────────────────
            if (device.isConnected) ...[
              const SizedBox(height: 14),
              const Divider(height: 1, color: Color(0xFFEEF2F7)),
              const SizedBox(height: 14),
              Row(
                children: [
                  if (device.isAlarmActive)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => _stopAlarm(device),
                        icon: const Icon(Icons.volume_off_rounded, size: 16),
                        label: const Text("Stop Alarm"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.danger,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                  if (device.isAlarmActive) const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: device.isAlarmActive
                          ? null
                          : () => _triggerAlarm(device),
                      icon: const Icon(Icons.campaign_rounded, size: 16),
                      label: const Text("Trigger Alarm"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        disabledForegroundColor:
                            AppColors.textMuted.withOpacity(0.5),
                        side: BorderSide(
                          color: device.isAlarmActive
                              ? AppColors.textMuted.withOpacity(0.3)
                              : AppColors.primary,
                          width: 1.2,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Stat Chip ─────────────────────────────────────────────────────────────
  // ── Metric tile untuk RSSI dan PRR ──────────────────────────────────────
  Widget _buildMetricTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color.withOpacity(0.8),
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ── Empty State ───────────────────────────────────────────────────────────
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_searching_rounded,
              size: 64, color: AppColors.textMuted.withOpacity(0.4)),
          const SizedBox(height: 16),
          const Text(
            "No devices added yet",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap "Add Device" to connect\nyour first BLE tracker.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textMuted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Danger Alert Dialog ───────────────────────────────────────────────────────
class _DangerAlertDialog extends StatelessWidget {
  final List<KidDevice> dangerDevices;
  final void Function(KidDevice device) onSeeDevice;
  final VoidCallback onDismiss;

  const _DangerAlertDialog({
    required this.dangerDevices,
    required this.onSeeDevice,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final bool isMultiple = dangerDevices.length > 1;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: AppColors.white,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.warning_rounded,
                  size: 36, color: AppColors.danger),
            ),
            const SizedBox(height: 16),
            Text(
              isMultiple ? "Multiple Children at Risk!" : "Child Out of Safe Zone!",
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textDark,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isMultiple
                  ? "${dangerDevices.length} children have left the safe zone."
                  : "has left the safe zone. Please check immediately.",
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            ...dangerDevices.map((device) => _buildDeviceRow(device)),
            const SizedBox(height: 20),
            if (!isMultiple) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => onSeeDevice(dangerDevices.first),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.danger,
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
                  child: const Text("See Device"),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onDismiss,
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
                child: const Text("Dismiss"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceRow(KidDevice device) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.person_rounded, size: 18, color: AppColors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              device.name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textDark,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.danger.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              device.distance.label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}