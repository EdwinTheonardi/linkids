// lib/core/services/device_repository.dart
//
// Menyimpan daftar device yang pernah di-add ke local storage.
// Yang disimpan hanya: id (MAC address) + name (nama yang diberikan user).
// Koneksi BLE sendiri tidak bisa di-persist — harus reconnect setiap buka app.
//
// pubspec.yaml — tambahkan:
//   shared_preferences: ^2.3.0

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

// ── Model ringan untuk data yang di-persist ───────────────────────────────────
class SavedDevice {
  final String id;   // MAC address ESP32-C3
  final String name; // Nama yang diberikan user

  const SavedDevice({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory SavedDevice.fromJson(Map<String, dynamic> json) => SavedDevice(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

// ── Repository ────────────────────────────────────────────────────────────────
class DeviceRepository {
  DeviceRepository._();
  static final DeviceRepository instance = DeviceRepository._();

  static const String _key = 'linkids_saved_devices';

  // ── Load semua device yang tersimpan ─────────────────────────────────────
  Future<List<SavedDevice>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key);
      if (raw == null || raw.isEmpty) return [];
      return raw
          .map((s) => SavedDevice.fromJson(jsonDecode(s)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Simpan device baru (skip jika id sudah ada) ───────────────────────────
  Future<void> save(SavedDevice device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadAll();

      // Jangan duplikat
      if (existing.any((d) => d.id == device.id)) return;

      existing.add(device);
      await prefs.setStringList(_key, existing.map((d) => jsonEncode(d.toJson())).toList());
    } catch (_) {}
  }

  // ── Update nama device ────────────────────────────────────────────────────
  Future<void> updateName(String deviceId, String newName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadAll();
      final updated = existing
          .map((d) => d.id == deviceId ? SavedDevice(id: d.id, name: newName) : d)
          .toList();
      await prefs.setStringList(_key, updated.map((d) => jsonEncode(d.toJson())).toList());
    } catch (_) {}
  }

  // ── Hapus satu device ─────────────────────────────────────────────────────
  Future<void> remove(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadAll();
      final filtered = existing.where((d) => d.id != deviceId).toList();
      await prefs.setStringList(_key, filtered.map((d) => jsonEncode(d.toJson())).toList());
    } catch (_) {}
  }
}