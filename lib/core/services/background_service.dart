import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:linkids/core/services/ble_service.dart';

// Background Task Handler
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_LinkidsTaskHandler());
}

class _LinkidsTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// BackgroundService
class BackgroundService {
  BackgroundService._();
  static final BackgroundService instance = BackgroundService._();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  bool _alarmNotificationShowing = false;

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // Channel ID
  static const String _foregroundChannelId = 'linkids_bg';
  static const String _alarmChannelId = 'linkids_alarm';
  static const int _alarmNotificationId = 9999;

  // Track stage per device
  final Map<String, AlertStage> _deviceStages = {};

  // Initialize
  Future<void> initialize() async {
    // Setup flutter_foreground_task
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _foregroundChannelId,
        channelName: 'Linkids Background',
        channelDescription: 'Indicates Linkids is running in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification:
            false, // iOS: sembunyikan notifikasi foreground service
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    // Setup flutter_local_notifications
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings),
    );

    // Channel untuk notifikasi background persistent (LOW - tidak bunyi)
    const AndroidNotificationChannel bgChannel = AndroidNotificationChannel(
      'linkids_bg_persistent',
      'Linkids Background',
      description: 'Indicates Linkids is running in the background',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    // Channel untuk alarm (MAX - pop-up dari atas)
    const AndroidNotificationChannel alarmChannel = AndroidNotificationChannel(
      _alarmChannelId,
      'Linkids Alarm',
      description: 'Linkids danger alert notification',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
    );

    final androidPlugin =
        _localNotifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

    await androidPlugin?.createNotificationChannel(bgChannel);
    await androidPlugin?.createNotificationChannel(alarmChannel);
  }

  // Request permission
  Future<void> requestPermissions() async {
    await FlutterForegroundTask.requestNotificationPermission();
  }

  // Start foreground service
  Future<void> start() async {
    if (_isRunning) return;
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'Linkids',
      notificationText: 'Linkids is running in the background',
      callback: startCallback,
    );

    _isRunning = true;

    // Tampilkan notifikasi background persistent via flutter_local_notifications
    await _showBackgroundNotification();
  }

  // Stop foreground service
  Future<void> stop() async {
    await FlutterForegroundTask.stopService();
    await _dismissAlarmNotification();
    await _hideBackgroundNotification();
    _isRunning = false;
    _deviceStages.clear();
  }

  // Dipanggil dari HomeScreen saat stage berubah
  Future<void> notifyAlarmStage(
    AlertStage stage,
    String deviceName,
    String deviceId,
  ) async {
    _deviceStages[deviceId] = stage;

    final worstStage = _getWorstActiveStage();

    if (worstStage == AlertStage.stage2) {
      // Stage 2 - tampilkan notifikasi popup urgent
      await _showAlarmNotification(
        title: '🚨 DANGER — $deviceName',
        body: 'Your child is outside the safe zone! Open the app now.',
      );
    }
    // Stage 1 dan none - tidak ada perubahan pada notifikasi
  }

  // Hapus stage device saat device di-remove
  void clearDeviceStage(String deviceId) {
    _deviceStages.remove(deviceId);
  }

  // Dismiss alarm notification - dipanggil saat user dismiss dialog
  Future<void> dismissAlarmNotification() async {
    await _dismissAlarmNotification();
    // Reset semua stage ke none karena user sudah acknowledge
    _deviceStages.updateAll((key, value) => AlertStage.none);
  }

  // Tampilkan alarm notification (persistent, tidak bisa diswipe)
  Future<void> _showAlarmNotification({
    required String title,
    required String body,
  }) async {
    _alarmNotificationShowing = true;

    await _localNotifications.show(
      _alarmNotificationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _alarmChannelId,
          'Linkids Alarm',
          channelDescription: 'Linkids danger alert notification',
          importance: Importance.max,
          priority: Priority.max,
          ongoing: true, // ← tidak bisa diswipe
          autoCancel: false, // ← tidak hilang saat di-tap
          fullScreenIntent: true, // ← tampil bahkan saat layar terkunci
          playSound: true,
          enableVibration: true,
          ticker: title,
          actions: [
            const AndroidNotificationAction(
              'open_app',
              'Open App',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ],
        ),
      ),
    );
  }

  // Tampilkan notifikasi background persistent (ganti foreground service notif)
  Future<void> _showBackgroundNotification() async {
    await _localNotifications.show(
      1001,
      'Linkids',
      'Linkids is running in the background',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'linkids_bg_persistent',
          'Linkids Background',
          channelDescription: 'Indicates Linkids is running in the background',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true, // ← tidak bisa diswipe
          autoCancel: false,
          playSound: false,
          enableVibration: false,
          showWhen: false,
        ),
      ),
    );
  }

  // Hapus notifikasi background
  Future<void> _hideBackgroundNotification() async {
    await _localNotifications.cancel(1001);
  }

  // Hapus alarm notification
  Future<void> _dismissAlarmNotification() async {
    if (!_alarmNotificationShowing) return;
    await _localNotifications.cancel(_alarmNotificationId);
    _alarmNotificationShowing = false;
  }

  // Cari stage terburuk dari semua device
  AlertStage _getWorstActiveStage() {
    if (_deviceStages.values.any((s) => s == AlertStage.stage2)) {
      return AlertStage.stage2;
    }
    if (_deviceStages.values.any((s) => s == AlertStage.stage1)) {
      return AlertStage.stage1;
    }
    return AlertStage.none;
  }
}
