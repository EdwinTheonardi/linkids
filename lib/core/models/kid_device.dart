import 'package:flutter/material.dart';
import 'package:linkids/core/constants/app_colors.dart';

// Enum Distance
enum DeviceDistance { veryClose, close, far, outOfRange }

extension DeviceDistanceExtension on DeviceDistance {
  String get label {
    switch (this) {
      case DeviceDistance.veryClose:
        return "Very Close";
      case DeviceDistance.close:
        return "Close";
      case DeviceDistance.far:
        return "Far";
      case DeviceDistance.outOfRange:
        return "Out of Range";
    }
  }
}

// Enum Zone
enum AlarmZone { safe, caution, danger }

extension AlarmZoneExtension on AlarmZone {
  String get label {
    switch (this) {
      case AlarmZone.safe:
        return "Safe";
      case AlarmZone.caution:
        return "Caution";
      case AlarmZone.danger:
        return "Danger";
    }
  }

  Color get color {
    switch (this) {
      case AlarmZone.safe:
        return AppColors.accent;
      case AlarmZone.caution:
        return AppColors.warning;
      case AlarmZone.danger:
        return AppColors.danger;
    }
  }

  Color get backgroundColor => color.withValues(alpha: 0.12);
  Color get borderColor => color.withValues(alpha: 0.4);
}

// Helper: zona dari jarak
AlarmZone zoneFromDistance(DeviceDistance distance) {
  switch (distance) {
    case DeviceDistance.veryClose:
      return AlarmZone.safe;
    case DeviceDistance.close:
      return AlarmZone.caution;
    case DeviceDistance.far:
      return AlarmZone.danger;
    case DeviceDistance.outOfRange:
      return AlarmZone.danger;
  }
}

// Model KidDevice
class KidDevice {
  final String id; // MAC address ESP32-C3
  final String name; // Nama yang diberikan user
  final bool isConnected;
  final DeviceDistance distance;
  final double signalStrength; // 0.0 – 1.0 (dari RSSI)
  final bool isAlarmActive;
  final int? rssiAverage; // Hasil sliding window

  const KidDevice({
    required this.id,
    required this.name,
    required this.isConnected,
    required this.distance,
    required this.signalStrength,
    this.isAlarmActive = false,
    this.rssiAverage,
  });

  AlarmZone get zone =>
      isConnected ? zoneFromDistance(distance) : AlarmZone.danger;

  KidDevice copyWith({
    String? name,
    bool? isConnected,
    DeviceDistance? distance,
    double? signalStrength,
    bool? isAlarmActive,
    int? rssiAverage,
  }) {
    return KidDevice(
      id: id,
      name: name ?? this.name,
      isConnected: isConnected ?? this.isConnected,
      distance: distance ?? this.distance,
      signalStrength: signalStrength ?? this.signalStrength,
      isAlarmActive: isAlarmActive ?? this.isAlarmActive,
      rssiAverage: rssiAverage ?? this.rssiAverage,
    );
  }
}
