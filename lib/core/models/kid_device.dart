// lib/core/models/kid_device.dart
// ── File ini adalah single source of truth untuk semua model dan enum ─────────
// Diimport oleh home_screen.dart, add_device_screen.dart, dan ble_service.dart

import 'package:flutter/material.dart';
import 'package:linkids/core/constants/app_colors.dart';

// ── Enum Distance ─────────────────────────────────────────────────────────────
enum DeviceDistance {
  veryClose,
  close,
  far,
  outOfRange,
}

extension DeviceDistanceExtension on DeviceDistance {
  String get label {
    switch (this) {
      case DeviceDistance.veryClose:  return "Very Close";
      case DeviceDistance.close:      return "Close";
      case DeviceDistance.far:        return "Far";
      case DeviceDistance.outOfRange: return "Out of Range";
    }
  }
}

// ── Enum Zone ─────────────────────────────────────────────────────────────────
enum AlarmZone { safe, caution, danger }

extension AlarmZoneExtension on AlarmZone {
  String get label {
    switch (this) {
      case AlarmZone.safe:    return "Safe";
      case AlarmZone.caution: return "Caution";
      case AlarmZone.danger:  return "Danger";
    }
  }

  Color get color {
    switch (this) {
      case AlarmZone.safe:    return AppColors.accent;
      case AlarmZone.caution: return AppColors.warning;
      case AlarmZone.danger:  return AppColors.danger;
    }
  }

  Color get backgroundColor => color.withOpacity(0.12);
  Color get borderColor      => color.withOpacity(0.4);
}

// ── Helper: zona dari jarak ───────────────────────────────────────────────────
AlarmZone zoneFromDistance(DeviceDistance distance) {
  switch (distance) {
    case DeviceDistance.veryClose:  return AlarmZone.safe;
    case DeviceDistance.close:      return AlarmZone.caution;
    case DeviceDistance.far:        return AlarmZone.danger;
    case DeviceDistance.outOfRange: return AlarmZone.danger;
  }
}

// Sentinel object untuk membedakan "tidak di-pass" vs "di-pass null" di copyWith
const _sentinel = Object();

// ── Model KidDevice ───────────────────────────────────────────────────────────
class KidDevice {
  final String id;             // MAC address ESP32-C3
  final String name;           // Nama yang diberikan user (bisa di-rename)
  final bool isConnected;
  final DeviceDistance distance;
  final double signalStrength; // 0.0 – 1.0 (dari RSSI)
  final bool isAlarmActive;
  final int? rssiAverage;      // DEBUG: nilai RSSI average dari sliding window
  final double? prrValue;      // DEBUG: nilai PRR saat ini (0.0–1.0)

  const KidDevice({
    required this.id,
    required this.name,
    required this.isConnected,
    required this.distance,
    required this.signalStrength,
    this.isAlarmActive = false,
    this.rssiAverage,
    this.prrValue,
  });

  AlarmZone get zone =>
      isConnected ? zoneFromDistance(distance) : AlarmZone.danger;

  KidDevice copyWith({
    String? name,
    bool? isConnected,
    DeviceDistance? distance,
    double? signalStrength,
    bool? isAlarmActive,
    Object? rssiAverage = _sentinel,  // pakai sentinel agar bisa update ke null
    Object? prrValue    = _sentinel,  // pakai sentinel agar bisa update ke null
  }) {
    return KidDevice(
      id: id,
      name: name ?? this.name,
      isConnected: isConnected ?? this.isConnected,
      distance: distance ?? this.distance,
      signalStrength: signalStrength ?? this.signalStrength,
      isAlarmActive: isAlarmActive ?? this.isAlarmActive,
      rssiAverage: rssiAverage == _sentinel ? this.rssiAverage : rssiAverage as int?,
      prrValue:    prrValue    == _sentinel ? this.prrValue    : prrValue    as double?,
    );
  }
}