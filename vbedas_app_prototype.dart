import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:android_intent_plus/android_intent.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geocoding/geocoding.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════

const Duration kMinAlertDuration  = Duration(seconds: 20);
const Duration kCoincidenceWindow = Duration(seconds: 5);

const String kAlertChannelId   = 'vbedas_eq_alert_v30';
const String kAlertChannelName = 'VBEDAS Earthquake Critical Alerts';
const String kSvcChannelId     = 'vbedas_svc_v30';
const String kSvcChannelName   = 'VBEDAS Background Monitor';

const int kAlertNotifId = 9001;
const int kSvcNotifId   = 777;

// ═══════════════════════════════════════════════════════════════════════════════
//  GLOBALS
// ═══════════════════════════════════════════════════════════════════════════════

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

AudioPlayer _makePlayer() => AudioPlayer();
AudioPlayer alarmPlayer = _makePlayer();

bool      _alertActive    = false;
bool      _alertDismissed = false;
DateTime? _alertStartTime;
Timer?    _alertMinTimer;

DateTime? _n1VibTime;
DateTime? _n2VibTime;

const FirebaseOptions firebaseOptions = FirebaseOptions(
  apiKey:            'AIzaSyC_VAznxpLqoi9xiCXa1SlTNCIaLT4qrRc',
  authDomain:        'vbedas.firebaseapp.com',
  databaseURL:       'https://vbedas-default-rtdb.asia-southeast1.firebasedatabase.app',
  projectId:         'vbedas',
  storageBucket:     'vbedas.firebasestorage.app',
  messagingSenderId: '38863431120',
  appId:             '1:38863431120:web:7200dc3feda823673645d5',
);

// ═══════════════════════════════════════════════════════════════════════════════
//  DATA HELPERS  — reads every plausible Firebase key name
// ═══════════════════════════════════════════════════════════════════════════════

Map<String, dynamic> safeMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};

double safeDouble(dynamic v, [double fallback = 0.0]) =>
    double.tryParse(v?.toString() ?? '') ?? fallback;

bool isAlertStatus(String s) {
  final l = s.toLowerCase();
  return l.contains('alert')      ||
         l.contains('earthquake') ||
         l.contains('confirmed')  ||
         l.contains('detected');
}

bool nodeIsShaking(Map<String, dynamic> node) {
  final s = (node['status'] ?? '').toString().toLowerCase();
  return node['shaking'] == true   ||
         node['shaking'] == 'true' ||
         s.contains('vibrat')      ||
         s.contains('shaking')     ||
         isAlertStatus(s);
}

/// Reads acceleration from a node, trying every key the ESP32 firmware might use.
double nodeAccel(Map<String, dynamic> node) => safeDouble(
  node['acceleration'] ??
  node['accel']        ??
  node['acc']          ??
  node['Acceleration'] ??
  node['value']        ??
  0.0,
);

/// Reads raw magnitude from a node.
double nodeRaw(Map<String, dynamic> node) => safeDouble(
  node['rawMag']       ??
  node['raw_mag']      ??
  node['raw']          ??
  node['magnitude']    ??
  node['rawMagnitude'] ??
  nodeAccel(node),       // fall back to acceleration if raw not present
);

/// Reads delta (Node 2 specific).
double nodeDelta(Map<String, dynamic> node) => safeDouble(
  node['delta']        ??
  node['Delta']        ??
  node['diff']         ??
  nodeAccel(node),
);

/// Reads threshold from a node.
double nodeThreshold(Map<String, dynamic> node, [double fallback = 0.2]) =>
    safeDouble(node['threshold'] ?? node['Threshold'] ?? node['limit'], fallback);

/// Returns the best "current acceleration" for the whole system.
double deriveAcceleration(
  Map<String, dynamic> node1,
  Map<String, dynamic> node2,
  Map<String, dynamic> events,
) {
  final a1 = nodeAccel(node1);
  final a2 = nodeDelta(node2);
  final ev = latestAlertEvent(events);
  final ae = safeDouble(ev['acceleration'] ?? ev['delta'] ?? ev['accel'], 0.0);
  return [a1, a2, ae].reduce((a, b) => a > b ? a : b);
}

double deriveThreshold(Map<String, dynamic> node1, Map<String, dynamic> node2) {
  final t1 = nodeThreshold(node1, 0.0);
  if (t1 > 0) return t1;
  final t2 = nodeThreshold(node2, 0.0);
  if (t2 > 0) return t2;
  return 0.2;
}

String deriveStatus(
  Map<String, dynamic> node1,
  Map<String, dynamic> node2,
  Map<String, dynamic> events,
) {
  final s1 = (node1['status'] ?? 'Normal').toString();
  final s2 = (node2['status'] ?? 'Normal').toString();
  if (isAlertStatus(s1) || isAlertStatus(s2)) return 'Alert';
  final latest = latestAlertEvent(events);
  if (isAlertStatus((latest['status'] ?? '').toString())) return 'Alert';
  if (nodeIsShaking(node1) || nodeIsShaking(node2)) return 'Vibrating';
  return 'Normal';
}

Map<String, dynamic> latestAlertEvent(Map<String, dynamic> events) {
  Map<String, dynamic> latest = {};
  for (final v in events.values) {
    final e = safeMap(v);
    if (isAlertStatus((e['status'] ?? '').toString())) latest = e;
  }
  return latest;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  NOTIFICATION SETUP
// ═══════════════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse r) {
  if (r.actionId == 'dismiss') _dismissAlert();
}

Future<void> setupNotifications() async {
  await notifications.initialize(
    const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: (r) async {
      if (r.actionId == 'dismiss') await _dismissAlert();
    },
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  final p = notifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (p == null) return;

  await p.requestNotificationsPermission();
  await p.requestExactAlarmsPermission();

  await p.createNotificationChannel(const AndroidNotificationChannel(
    kAlertChannelId, kAlertChannelName,
    description:          'VBEDAS earthquake alert — never silence this',
    importance:           Importance.max,
    playSound:            true,
    enableVibration:      true,
    sound:                RawResourceAndroidNotificationSound('alert'),
    audioAttributesUsage: AudioAttributesUsage.alarm,
    showBadge:            true,
  ));

  await p.createNotificationChannel(const AndroidNotificationChannel(
    kSvcChannelId, kSvcChannelName,
    description:     'VBEDAS is monitoring in the background',
    importance:      Importance.low,
    playSound:       false,
    enableVibration: false,
    showBadge:       false,
  ));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ALERT NOTIFICATION
// ═══════════════════════════════════════════════════════════════════════════════

Future<void> fireAlertNotification({
  required String status,
  required double acceleration,
  String nodeInfo = 'VBEDAS Alert',
  bool   force   = false,
}) async {
  if (_alertDismissed && !force) return;

  if (force) {
    _alertDismissed = false;
    _alertActive    = false;
    _alertStartTime = null;
    _alertMinTimer?.cancel();
    _alertMinTimer  = null;
    try { await notifications.cancel(kAlertNotifId); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 200));
  }

  if (_alertActive && _alertStartTime != null) {
    final elapsed = DateTime.now().difference(_alertStartTime!);
    if (elapsed < kMinAlertDuration) return;
  }

  try { await WakelockPlus.enable(); } catch (_) {}

  _alertActive    = true;
  _alertStartTime = DateTime.now();

  final body =
      'Accel: ${acceleration.toStringAsFixed(4)} m/s²  |  $nodeInfo';

  await notifications.show(
    kAlertNotifId,
    '⚠ EARTHQUAKE DETECTED',
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        kAlertChannelId, kAlertChannelName,
        channelDescription:   'VBEDAS earthquake alert — never silence this',
        importance:           Importance.max,
        priority:             Priority.max,
        fullScreenIntent:     true,
        category:             AndroidNotificationCategory.alarm,
        sound:                const RawResourceAndroidNotificationSound('alert'),
        audioAttributesUsage: AudioAttributesUsage.alarm,
        playSound:            true,
        enableVibration:      true,
        vibrationPattern:
            Int64List.fromList([0, 1000, 300, 1000, 300, 1000, 300, 2000]),
        ticker:      'VBEDAS EARTHQUAKE ALERT',
        enableLights: true,
        ledColor:    const Color(0xFFFF0000),
        ledOnMs:     300,
        ledOffMs:    100,
        ongoing:     true,
        autoCancel:  false,
        onlyAlertOnce: false,
        color:       const Color(0xFFFF0000),
        colorized:   true,
        visibility:  NotificationVisibility.public,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: 'EARTHQUAKE — $status',
          summaryText:  'VBEDAS · Dual Node Confirmed',
        ),
        actions: const [
          AndroidNotificationAction(
            'dismiss', 'DISMISS ALERT',
            cancelNotification: false,
            showsUserInterface: true,
          ),
        ],
      ),
    ),
  );

  await _playAlarmSound();

  _alertMinTimer?.cancel();
  _alertMinTimer = Timer(kMinAlertDuration, () {
    if (_alertDismissed) _hardCancelAlert();
  });
}

Future<void> _playAlarmSound() async {
  try {
    try { await alarmPlayer.stop(); } catch (_) {}
    alarmPlayer = _makePlayer();
    await alarmPlayer.setReleaseMode(ReleaseMode.loop);
    await alarmPlayer.setVolume(1.0);
    await alarmPlayer.play(AssetSource('sound/alert.mp3'));
  } catch (e) { debugPrint('Alarm sound error: $e'); }
}

Future<void> _dismissAlert() async {
  _alertDismissed = true;
  await _hardCancelAlert();
}

Future<void> _hardCancelAlert() async {
  _alertActive    = false;
  _alertStartTime = null;
  _alertMinTimer?.cancel();
  _alertMinTimer  = null;
  try { await notifications.cancel(kAlertNotifId); } catch (_) {}
  try { await alarmPlayer.stop(); }                 catch (_) {}
  try { await WakelockPlus.disable(); }             catch (_) {}
}

Future<void> cancelAlertIfSafe() async {
  if (!_alertActive) return;
  if (_alertDismissed) { await _hardCancelAlert(); return; }
  if (_alertStartTime == null) { await _hardCancelAlert(); return; }
  final elapsed = DateTime.now().difference(_alertStartTime!);
  if (elapsed >= kMinAlertDuration) await _hardCancelAlert();
}

Future<void> _showServiceNotif(String content) async {
  await notifications.show(
    kSvcNotifId, 'VBEDAS Active', content,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        kSvcChannelId, kSvcChannelName,
        importance:      Importance.low,
        priority:        Priority.low,
        ongoing:         true,
        autoCancel:      false,
        playSound:       false,
        enableVibration: false,
        icon:            '@mipmap/ic_launcher',
        visibility:      NotificationVisibility.public,
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  BACKGROUND SERVICE
// ═══════════════════════════════════════════════════════════════════════════════

Future<void> initializeBackgroundService() async {
  final svc = FlutterBackgroundService();
  await svc.configure(
    androidConfiguration: AndroidConfiguration(
      onStart:                         onBackgroundServiceStart,
      autoStart:                       true,
      isForegroundMode:                true,
      autoStartOnBoot:                 true,
      foregroundServiceNotificationId: kSvcNotifId,
      initialNotificationTitle:        'VBEDAS Active',
      initialNotificationContent:      'Monitoring for earthquakes…',
      notificationChannelId:           kSvcChannelId,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
  if (!await svc.isRunning()) await svc.startService();
}

@pragma('vm:entry-point')
void onBackgroundServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: firebaseOptions);
  }
  await setupNotifications();
  alarmPlayer = _makePlayer();
  await _showServiceNotif('Monitoring for earthquakes…');

  DateTime? bgN1VibTime;
  DateTime? bgN2VibTime;
  String    lastSig   = '';
  DateTime? lastAlert;

  final dbRef = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
        'https://vbedas-default-rtdb.asia-southeast1.firebasedatabase.app',
  ).ref();

  Timer.periodic(const Duration(seconds: 20), (_) async {
    try { await dbRef.child('.info/connected').get(); } catch (_) {}
  });

  dbRef.onValue.listen((event) async {
    final data   = safeMap(event.snapshot.value);
    final node1  = safeMap(data['node1']);
    final node2  = safeMap(data['node2']);
    final events = safeMap(data['events']);

    if (_bgNodeIsShaking(node1)) bgN1VibTime = DateTime.now();
    if (_bgNodeIsShaking(node2)) bgN2VibTime = DateTime.now();

    final inWindow = bgN1VibTime != null &&
        bgN2VibTime != null &&
        bgN1VibTime!.difference(bgN2VibTime!).abs() <= kCoincidenceWindow;

    final status = deriveStatus(node1, node2, events);
    final accel  = deriveAcceleration(node1, node2, events);
    final info   =
        'N1:${node1["status"] ?? "OK"}  N2:${node2["status"] ?? "OK"}';
    final sig =
        '$status|${events.length}|${node1["timestamp"]}|${node2["timestamp"]}';

    final shouldAlert = isAlertStatus(status) || inWindow;

    if (shouldAlert && !_alertDismissed) {
      final now    = DateTime.now();
      final repeat = lastAlert == null ||
          now.difference(lastAlert!).inSeconds >= 20;
      if (lastSig != sig || repeat) {
        lastSig         = sig;
        lastAlert       = now;
        _alertDismissed = false;
        await fireAlertNotification(
          status:       status.isEmpty ? 'Dual-Node Alert' : status,
          acceleration: accel,
          nodeInfo:     info,
        );
      }
    } else if (!shouldAlert) {
      if (_alertActive) await cancelAlertIfSafe();
      if (!_alertActive) {
        lastSig         = '';
        lastAlert       = null;
        _alertDismissed = false;
        bgN1VibTime     = null;
        bgN2VibTime     = null;
        await _showServiceNotif('All clear — monitoring…');
      }
    }
  }, onError: (e) => debugPrint('Firebase stream error: $e'));

  service.on('stop').listen((_) async {
    await _hardCancelAlert();
    await service.stopSelf();
  });
}

bool _bgNodeIsShaking(Map<String, dynamic> node) {
  final s = (node['status'] ?? '').toString().toLowerCase();
  return node['shaking'] == true   ||
         node['shaking'] == 'true' ||
         s.contains('vibrat')      ||
         s.contains('shaking')     ||
         isAlertStatus(s);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  OTHER UTILITIES
// ═══════════════════════════════════════════════════════════════════════════════

Future<void> openDndSettings() async =>
    const AndroidIntent(
      action: 'android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS',
    ).launch();

Future<Position?> getLocationWithPermission() async {
  try {
    PermissionStatus perm = await Permission.locationWhenInUse.status;
    if (perm.isDenied) perm = await Permission.locationWhenInUse.request();
    if (perm.isPermanentlyDenied) { await openAppSettings(); return null; }
    if (!perm.isGranted) return null;
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings(); return null;
    }
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15)),
    );
  } catch (e) { debugPrint('Location error: $e'); return null; }
}

Future<String?> getReadableLocationName(Position p) async {
  try {
    final ms = await placemarkFromCoordinates(p.latitude, p.longitude);
    if (ms.isEmpty) return null;
    final m       = ms.first;
    final city    = _firstNonEmpty(
        [m.locality, m.subAdministrativeArea, m.administrativeArea]);
    final country = _firstNonEmpty([m.country, m.isoCountryCode]);
    if (city != null && country != null) return '$city, $country';
    return city ?? country;
  } catch (e) { debugPrint('Geocode error: $e'); return null; }
}

String? _firstNonEmpty(List<String?> vals) {
  for (final v in vals) {
    final t = v?.trim();
    if (t != null && t.isNotEmpty) return t;
  }
  return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Firebase.initializeApp(options: firebaseOptions);
  await setupNotifications();
  await _requestPermissions();
  await initializeBackgroundService();
  runApp(const VBEDASApp());
}

Future<void> _requestPermissions() async {
  try {
    if (!await Permission.ignoreBatteryOptimizations.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  } catch (_) {}
  try {
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }
  } catch (_) {}
}

// ═══════════════════════════════════════════════════════════════════════════════
//  APP ROOT
// ═══════════════════════════════════════════════════════════════════════════════

class VBEDASApp extends StatelessWidget {
  const VBEDASApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VBEDAS',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed:         Colors.red,
          useMaterial3:            true,
          scaffoldBackgroundColor: const Color(0xFFF4F6F8),
          cardTheme: CardThemeData(
            elevation: 0,
            color:     Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
          ),
        ),
        home: const MainScreen(),
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  NAVIGATION SHELL
// ═══════════════════════════════════════════════════════════════════════════════

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _i = 0;
  static const _pages = [
    DashboardPage(), HistoryPage(), NodeStatusPage(), SafetyPage(), SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(children: [
          _pages[_i],
          const Positioned(right: 12, bottom: 12, child: _FbBadge()),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _i,
          onDestinationSelected: (v) => setState(() => _i = v),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard_rounded),        label: 'Dashboard'),
            NavigationDestination(icon: Icon(Icons.history_rounded),           label: 'History'),
            NavigationDestination(icon: Icon(Icons.sensors_rounded),           label: 'Nodes'),
            NavigationDestination(icon: Icon(Icons.health_and_safety_rounded), label: 'Safety'),
            NavigationDestination(icon: Icon(Icons.settings_rounded),          label: 'Settings'),
          ],
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  DASHBOARD PAGE  — fully reactive to Firebase node data
// ═══════════════════════════════════════════════════════════════════════════════

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardState();
}

class _DashboardState extends State<DashboardPage> with WidgetsBindingObserver {
  final _db = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
        'https://vbedas-default-rtdb.asia-southeast1.firebasedatabase.app',
  ).ref();

  // Foreground coincidence timestamps
  DateTime? _fgN1VibTime;
  DateTime? _fgN2VibTime;

  // Alert de-dup
  String    _lastFgSig  = '';
  DateTime? _lastFgTime;

  // Location
  Position? _pos;
  String?   _locName;
  bool      _locLoading = false;
  String?   _locError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLoc());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadLoc() async {
    setState(() { _locLoading = true; _locError = null; _locName = null; });
    final pos  = await getLocationWithPermission();
    final name = pos != null ? await getReadableLocationName(pos) : null;
    if (!mounted) return;
    setState(() {
      _pos        = pos;
      _locName    = name;
      _locLoading = false;
      _locError   = pos == null
          ? 'Location unavailable. Tap to retry.'
          : name == null ? 'Location found, place name unavailable.' : null;
    });
  }

  void _processFgAlert(
    Map<String, dynamic> node1,
    Map<String, dynamic> node2,
    Map<String, dynamic> events,
    String status,
    double accel,
    String info,
  ) {
    // Record vibration timestamps for each node
    if (nodeIsShaking(node1) || isAlertStatus((node1['status'] ?? '').toString())) {
      setState(() => _fgN1VibTime = DateTime.now());
    }
    if (nodeIsShaking(node2) || isAlertStatus((node2['status'] ?? '').toString())) {
      setState(() => _fgN2VibTime = DateTime.now());
    }

    final inWindow = _fgN1VibTime != null &&
        _fgN2VibTime != null &&
        _fgN1VibTime!.difference(_fgN2VibTime!).abs() <= kCoincidenceWindow;

    final shouldAlert = isAlertStatus(status) || inWindow;
    final sig =
        '$status|${events.length}|${node1["timestamp"]}|${node2["timestamp"]}';

    if (shouldAlert && !_alertDismissed) {
      final now    = DateTime.now();
      final repeat = _lastFgTime == null ||
          now.difference(_lastFgTime!).inSeconds >= 20;
      if (_lastFgSig != sig || repeat) {
        _lastFgSig      = sig;
        _lastFgTime     = now;
        _alertDismissed = false;
        fireAlertNotification(
          status:       status.isEmpty ? 'Dual-Node Alert' : status,
          acceleration: accel,
          nodeInfo:     info,
        );
      }
    } else if (!shouldAlert) {
      _alertDismissed = false;
      cancelAlertIfSafe();
      if (!_alertActive) {
        _lastFgSig   = '';
        _lastFgTime  = null;
        setState(() { _fgN1VibTime = null; _fgN2VibTime = null; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: _db.onValue,
      builder: (ctx, snap) {
        // ── loading / error states ──
        if (snap.hasError) {
          return const Center(
              child: Text('Firebase error — check connection'));
        }
        if (!snap.hasData || snap.data?.snapshot.value == null) {
          return const Center(child: CircularProgressIndicator());
        }

        // ── parse snapshot ──
        final raw    = safeMap(snap.data!.snapshot.value);
        final node1  = safeMap(raw['node1']);
        final node2  = safeMap(raw['node2']);
        final tests  = safeMap(raw['tests']);
        final events = safeMap(raw['events']);

        // ── derive display values ──
        final status = deriveStatus(node1, node2, events);
        final accel  = deriveAcceleration(node1, node2, events);
        final thresh = deriveThreshold(node1, node2);

        // Node-specific readings shown on cards
        final n1Accel  = nodeAccel(node1);
        final n1Raw    = nodeRaw(node1);
        final n1Thr    = nodeThreshold(node1, 0.20);
        final n1Status = (node1['status'] ?? 'Normal').toString();
        final n1Shake  = nodeIsShaking(node1);
        final n1Online = node1['online'] == true || node1['online'] == 'true';

        final n2Delta  = nodeDelta(node2);
        final n2Raw    = nodeRaw(node2);
        final n2Thr    = nodeThreshold(node2, 0.25);
        final n2Status = (node2['status'] ?? 'Normal').toString();
        final n2Shake  = nodeIsShaking(node2);
        final n2Online = node2['online'] == true || node2['online'] == 'true';

        final totalT  = safeDouble(tests['totalTests'],        0.0);
        final correct = safeDouble(tests['correctDetections'], 0.0);
        final reliab  = totalT == 0 ? 0.0 : (correct / totalT) * 100;

        final evList = events.values.map((e) => safeMap(e)).toList();
        final graphEvs = evList
            .where((e) => isAlertStatus((e['status'] ?? '').toString()))
            .toList();

        final info =
            'N1:$n1Status  N2:$n2Status';

        // ── alert logic (post-frame to avoid setState during build) ──
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => _processFgAlert(node1, node2, events, status, accel, info));

        final inWindow = _fgN1VibTime != null &&
            _fgN2VibTime != null &&
            _fgN1VibTime!.difference(_fgN2VibTime!).abs() <= kCoincidenceWindow;

        final displayStatus =
            isAlertStatus(status) || inWindow ? 'ALERT' : status;

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [

              // ── title ──
              const Text('VBEDAS Dashboard',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('System state: $displayStatus',
                  style: TextStyle(
                    fontSize: 13,
                    color: isAlertStatus(displayStatus)
                        ? Colors.red
                        : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  )),
              const SizedBox(height: 16),

              // ── status banner ──
              _Banner(status: displayStatus),
              const SizedBox(height: 12),

              // ── background service pill ──
              const _SvcCard(),
              const SizedBox(height: 16),

              // ── coincidence window card ──
              _CoincidenceCard(
                  n1Time: _fgN1VibTime, n2Time: _fgN2VibTime),
              const SizedBox(height: 16),

              // ── 4 metric cards ──
              GridView.count(
                crossAxisCount:   2,
                shrinkWrap:       true,
                physics:          const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.3,
                crossAxisSpacing: 12,
                mainAxisSpacing:  12,
                children: [
                  _MetricCard(
                    title:    'Peak Acceleration',
                    value:    accel.toStringAsFixed(4),
                    unit:     'm/s²',
                    icon:     Icons.speed_rounded,
                    color:    Colors.red,
                    subLabel: 'N1: ${n1Accel.toStringAsFixed(4)}  N2: ${n2Delta.toStringAsFixed(4)}',
                  ),
                  _MetricCard(
                    title:    'Threshold',
                    value:    thresh.toStringAsFixed(2),
                    unit:     'm/s²',
                    icon:     Icons.tune_rounded,
                    color:    Colors.blue,
                    subLabel: 'N1: ${n1Thr.toStringAsFixed(2)}  N2: ${n2Thr.toStringAsFixed(2)}',
                  ),
                  _MetricCard(
                    title:    'Total Events',
                    value:    '${evList.length}',
                    unit:     'logged',
                    icon:     Icons.warning_amber_rounded,
                    color:    Colors.orange,
                    subLabel: 'Alert events only',
                  ),
                  _MetricCard(
                    title:    'Reliability',
                    value:    reliab.toStringAsFixed(1),
                    unit:     '%',
                    icon:     Icons.verified_rounded,
                    color:    Colors.green,
                    subLabel: '$correct / $totalT correct',
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── live node summary ──
              const _SecTitle('Live Node Readings'),
              Row(children: [
                Expanded(
                  child: _NodeSummaryCard(
                    title:    'Node 1 — Display',
                    subtitle: 'ESP32 · MPU6050 · OLED',
                    status:   n1Status,
                    accelLabel: 'Acceleration',
                    accel:    n1Accel.toStringAsFixed(4),
                    raw:      n1Raw.toStringAsFixed(4),
                    thr:      n1Thr.toStringAsFixed(2),
                    shaking:  n1Shake,
                    online:   n1Online,
                    ts:       (node1['timestamp'] ?? '—').toString(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _NodeSummaryCard(
                    title:    'Node 2 — SMS',
                    subtitle: 'ESP32 · MPU6050 · SIM800L',
                    status:   n2Status,
                    accelLabel: 'Delta',
                    accel:    n2Delta.toStringAsFixed(4),
                    raw:      n2Raw.toStringAsFixed(4),
                    thr:      n2Thr.toStringAsFixed(2),
                    shaking:  n2Shake,
                    online:   n2Online,
                    ts:       (node2['timestamp'] ?? '—').toString(),
                  ),
                ),
              ]),
              const SizedBox(height: 20),

              // ── location ──
              const _SecTitle('Your Location'),
              _LocCard(
                pos: _pos, locName: _locName,
                loading: _locLoading, error: _locError,
                onRetry: _loadLoc,
              ),
              const SizedBox(height: 20),

              // ── graph ──
              const _SecTitle('Confirmed Detection Graph'),
              _Graph(events: graphEvs),
              const SizedBox(height: 20),

              // ── DND banner ──
              _DndBanner(onTap: openDndSettings),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  COINCIDENCE WINDOW CARD
// ═══════════════════════════════════════════════════════════════════════════════

class _CoincidenceCard extends StatelessWidget {
  final DateTime? n1Time;
  final DateTime? n2Time;
  const _CoincidenceCard({required this.n1Time, required this.n2Time});

  String _ts(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final both = n1Time != null && n2Time != null;
    final inWindow = both &&
        n1Time!.difference(n2Time!).abs() <= kCoincidenceWindow;
    final diffSec = both
        ? n1Time!.difference(n2Time!).abs().inMilliseconds / 1000.0
        : null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        inWindow ? Colors.red.shade50 : Colors.grey.shade50,
        border:       Border.all(
            color: inWindow ? Colors.red.shade300 : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            inWindow ? Icons.warning_rounded : Icons.sensors_rounded,
            color: inWindow ? Colors.red : Colors.grey.shade600,
            size:  18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              inWindow
                  ? '⚡ DUAL-NODE COINCIDENCE — ALERT ACTIVE'
                  : '5-Second Coincidence Window',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: inWindow ? Colors.red.shade800 : Colors.grey.shade700,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _pill('N1', n1Time != null ? _ts(n1Time!) : 'waiting',
              n1Time != null ? Colors.blue : Colors.grey),
          const SizedBox(width: 8),
          _pill('N2', n2Time != null ? _ts(n2Time!) : 'waiting',
              n2Time != null ? Colors.blue : Colors.grey),
          if (diffSec != null) ...[
            const SizedBox(width: 8),
            _pill('Gap', '${diffSec.toStringAsFixed(1)}s',
                inWindow ? Colors.red : Colors.orange),
          ],
        ]),
        const SizedBox(height: 6),
        Text(
          'Both nodes within ${kCoincidenceWindow.inSeconds}s → '
          '${kMinAlertDuration.inSeconds}s guaranteed alert',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
      ]),
    );
  }

  Widget _pill(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color:        color.withAlpha(20),
          border:       Border.all(color: color.withAlpha(80)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$label: $value',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold,
              color: color, fontFamily: 'monospace'),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  NODE SUMMARY CARD  (inline on dashboard — shows live values)
// ═══════════════════════════════════════════════════════════════════════════════

class _NodeSummaryCard extends StatelessWidget {
  final String title, subtitle, status, accelLabel, accel, raw, thr, ts;
  final bool shaking, online;
  const _NodeSummaryCard({
    required this.title,    required this.subtitle, required this.status,
    required this.accelLabel, required this.accel,  required this.raw,
    required this.thr,      required this.shaking,  required this.online,
    required this.ts,
  });

  @override
  Widget build(BuildContext context) {
    final alerting = isAlertStatus(status);
    final vibrating = status.toLowerCase().contains('vibrat');
    final statusColor = alerting
        ? Colors.red
        : vibrating
            ? Colors.orange
            : Colors.green;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: alerting
                ? Colors.red.shade300
                : shaking
                    ? Colors.orange.shade300
                    : Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(8),
              blurRadius: 8,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // header
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: online
                  ? Colors.green.shade100
                  : Colors.red.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              online ? 'ON' : 'OFF',
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: online
                      ? Colors.green.shade800
                      : Colors.red.shade800),
            ),
          ),
        ]),
        Text(subtitle,
            style:
                TextStyle(fontSize: 9, color: Colors.grey.shade500)),
        const Divider(height: 14),

        // rows
        _row('Status', status, statusColor),
        _row(accelLabel, '$accel m/s²', Colors.black87),
        _row('Raw Mag', '$raw m/s²', Colors.black87),
        _row('Threshold', '$thr m/s²', Colors.black87),
        _row('Shaking', shaking ? 'YES ⚡' : 'No',
            shaking ? Colors.orange.shade700 : Colors.black87),

        const SizedBox(height: 6),
        Text(
          'Sync: $ts',
          style: TextStyle(
              fontSize: 9,
              color: Colors.grey.shade400,
              fontFamily: 'monospace'),
          overflow: TextOverflow.ellipsis,
        ),
      ]),
    );
  }

  Widget _row(String label, String value, Color valColor) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
            Text(value,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: valColor,
                    fontFamily: 'monospace')),
          ],
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HISTORY PAGE
// ═══════════════════════════════════════════════════════════════════════════════

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: StreamBuilder<DatabaseEvent>(
        stream: FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL:
              'https://vbedas-default-rtdb.asia-southeast1.firebasedatabase.app',
        ).ref('events').onValue,
        builder: (ctx, snap) {
          if (snap.hasError)
            return const Center(child: Text('Firebase error'));
          if (!snap.hasData || snap.data?.snapshot.value == null)
            return const Center(child: Text('No alert history yet'));

          final evts = safeMap(snap.data!.snapshot.value)
              .values
              .map((e) => safeMap(e))
              .toList()
              .reversed
              .toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Alert History',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              if (evts.isEmpty)
                const Center(
                    child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('No events recorded yet')))
              else
                ...evts.map((ev) {
                  final status = (ev['status'] ?? 'Alert').toString();
                  final alert  = isAlertStatus(status);
                  final accel  = safeDouble(
                          ev['acceleration'] ?? ev['delta'] ?? ev['accel'])
                      .toStringAsFixed(4);
                  final thr   = safeDouble(ev['threshold'], 0.2)
                      .toStringAsFixed(2);
                  final nRaw  = (ev['node'] ?? '').toString();
                  final nLabel = nRaw == 'node1'
                      ? 'Node 1 (Display)'
                      : nRaw == 'node2'
                          ? 'Node 2 (SMS)'
                          : nRaw.isNotEmpty ? nRaw : 'Unknown';

                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: Icon(
                        alert
                            ? Icons.warning_rounded
                            : Icons.check_circle_rounded,
                        color: alert ? Colors.red : Colors.green,
                      ),
                      title: Text(status),
                      subtitle: Text(
                        'Node: $nLabel\n'
                        'Accel: $accel m/s²  Threshold: $thr m/s²\n'
                        'Time: ${ev["timestamp"] ?? ev["time"] ?? "N/A"}',
                      ),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  NODE STATUS PAGE
// ═══════════════════════════════════════════════════════════════════════════════

class NodeStatusPage extends StatelessWidget {
  const NodeStatusPage({super.key});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: StreamBuilder<DatabaseEvent>(
        stream: FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL:
              'https://vbedas-default-rtdb.asia-southeast1.firebasedatabase.app',
        ).ref().onValue,
        builder: (ctx, snap) {
          if (snap.hasError)
            return const Center(child: Text('Firebase error'));
          if (!snap.hasData || snap.data?.snapshot.value == null)
            return const Center(child: CircularProgressIndicator());

          final raw   = safeMap(snap.data!.snapshot.value);
          final node1 = safeMap(raw['node1']);
          final node2 = safeMap(raw['node2']);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Node Status',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _NodeCard(
                title:      'Node 1 — Primary Display Node',
                subtitle:   'ESP32 · MPU6050 · OLED · Buzzer · LED',
                status:     (node1['status'] ?? 'Normal').toString(),
                valueLabel: 'Acceleration',
                value:      '${nodeAccel(node1).toStringAsFixed(4)} m/s²',
                rawMag:     '${nodeRaw(node1).toStringAsFixed(4)} m/s²',
                threshold:  '${nodeThreshold(node1, 0.20).toStringAsFixed(2)} m/s²',
                shaking:    '${node1["shaking"] ?? false}',
                online:     '${node1["online"] ?? false}',
                uptime:     node1['uptime'] != null
                    ? '${node1["uptime"]} s' : '—',
                lastSeen:   (node1['timestamp'] ?? '—').toString(),
              ),
              const SizedBox(height: 12),
              _NodeCard(
                title:      'Node 2 — Secondary SMS Node',
                subtitle:   'ESP32 · MPU6050 · SIM800L',
                status:     (node2['status'] ?? 'Normal').toString(),
                valueLabel: 'Delta',
                value:      '${nodeDelta(node2).toStringAsFixed(4)} m/s²',
                rawMag:     '${nodeRaw(node2).toStringAsFixed(4)} m/s²',
                threshold:  '${nodeThreshold(node2, 0.25).toStringAsFixed(2)} m/s²',
                shaking:    '${node2["shaking"] ?? false}',
                online:     '${node2["online"] ?? false}',
                uptime:     node2['uptime'] != null
                    ? '${node2["uptime"]} s' : '—',
                lastSeen:   (node2['timestamp'] ?? '—').toString(),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: _deco(),
                child: const Text(
                  'Both nodes communicate via ESP-NOW. Any vibration on both '
                  'nodes within a 5-second window triggers a confirmed alert. '
                  'Single-node events are treated as local disturbances.',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SAFETY PAGE
// ═══════════════════════════════════════════════════════════════════════════════

class SafetyPage extends StatelessWidget {
  const SafetyPage({super.key});
  static const _tips = [
    'Drop, cover, and hold on during shaking.',
    'Stay away from windows and heavy objects.',
    'Do not use elevators during an earthquake.',
    'Move to an open area after shaking stops.',
    'Keep emergency contacts and first-aid kit ready.',
    'Follow official instructions from authorities.',
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Safety Guide',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ..._tips.map((t) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.health_and_safety_rounded),
                    title: Text(t),
                  ),
                )),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: _deco(),
              child: const Text(
                'This application is for local awareness only. It does not predict '
                'earthquakes or replace professional monitoring systems.',
              ),
            ),
          ],
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SETTINGS PAGE
// ═══════════════════════════════════════════════════════════════════════════════

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  bool _testing = false;

  Future<void> _test() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      await fireAlertNotification(
        status:       'TEST ALERT — Dual Node Simulation',
        acceleration: 1.25,
        nodeInfo:     'N1:ALERT  N2:ALERT  (test)',
        force:        true,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Test alert error: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Settings',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: _deco(),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Alert Test',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(
                      'Fires a test that holds for a minimum of '
                      '${kMinAlertDuration.inSeconds}s regardless of '
                      'Firebase state.',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: const Icon(
                          Icons.notification_important_rounded),
                      label: Text(_testing
                          ? 'Testing…'
                          : 'Fire Test Alert (${kMinAlertDuration.inSeconds}s min)'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => _hardCancelAlert(),
                      icon:  const Icon(Icons.stop_rounded),
                      label: const Text('Stop Alarm'),
                    ),
                  ]),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: _deco(),
              child: Column(children: [
                _ListTile(
                  icon:     Icons.notifications_rounded,
                  title:    'Notification Settings',
                  subtitle: 'Enable sound, popup, lock screen',
                  onTap:    openAppSettings,
                ),
                const Divider(height: 1),
                _ListTile(
                  icon:     Icons.do_not_disturb_off_rounded,
                  title:    'DND Override',
                  subtitle: 'Allow alerts in Do Not Disturb mode',
                  onTap:    openDndSettings,
                ),
                const Divider(height: 1),
                _ListTile(
                  icon:     Icons.battery_alert_rounded,
                  title:    'Battery Settings',
                  subtitle: 'Set app battery to Unrestricted',
                  onTap:    openAppSettings,
                ),
              ]),
            ),
          ],
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  REUSABLE UI WIDGETS
// ═══════════════════════════════════════════════════════════════════════════════

class _ListTile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const _ListTile(
      {required this.icon, required this.title,
       required this.subtitle, required this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
        leading:  Icon(icon),
        title:    Text(title),
        subtitle: Text(subtitle),
        onTap:    onTap,
      );
}

class _FbBadge extends StatelessWidget {
  const _FbBadge();
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color:        Colors.green,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                  color:     Colors.black.withAlpha(30),
                  blurRadius: 8,
                  offset:    const Offset(0, 3))
            ],
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_done_rounded, size: 15, color: Colors.white),
            SizedBox(width: 5),
            Text('Firebase Connected',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ]),
        ),
      );
}

class _Banner extends StatelessWidget {
  final String status;
  const _Banner({required this.status});
  @override
  Widget build(BuildContext context) {
    final alert = isAlertStatus(status);
    final vib   = status.toLowerCase().contains('vibrat');
    final color = alert ? Colors.red : vib ? Colors.orange : Colors.green;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width:   double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: color, borderRadius: BorderRadius.circular(18)),
      child: Row(children: [
        Icon(
          alert ? Icons.warning_rounded : Icons.check_circle_rounded,
          color: Colors.white, size: 30,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(status,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }
}

class _SvcCard extends StatefulWidget {
  const _SvcCard();
  @override
  State<_SvcCard> createState() => _SvcCardState();
}

class _SvcCardState extends State<_SvcCard> {
  bool? _running;
  @override
  void initState() { super.initState(); _check(); }
  Future<void> _check() async {
    final r = await FlutterBackgroundService().isRunning();
    if (mounted) setState(() => _running = r);
  }
  @override
  Widget build(BuildContext context) {
    final r = _running;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color:        r == true ? Colors.green.shade50 : Colors.red.shade50,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(
            color: r == true
                ? Colors.green.shade300
                : Colors.red.shade300),
      ),
      child: Row(children: [
        Icon(
          r == true
              ? Icons.gpp_good_rounded
              : Icons.gpp_maybe_rounded,
          color: r == true ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            r == true
                ? 'Background Protection Active'
                : 'Background Service Inactive',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: r == true
                    ? Colors.green.shade900
                    : Colors.red.shade900),
          ),
        ),
      ]),
    );
  }
}

/// Metric card with subtitle line showing per-node breakdown.
class _MetricCard extends StatelessWidget {
  final String title, value, unit, subLabel;
  final IconData icon;
  final Color color;
  const _MetricCard({
    required this.title,    required this.value,
    required this.unit,     required this.icon,
    required this.color,    required this.subLabel,
  });
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: _deco(),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment:  MainAxisAlignment.center,
            children: [
          Row(children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: 11,
                      color:    Colors.grey.shade600,
                      fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(
              text:  value,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                  fontFamily: 'monospace'),
              children: [
                TextSpan(
                  text:  ' $unit',
                  style: TextStyle(
                      fontSize: 11,
                      color:    Colors.grey.shade500,
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(subLabel,
              style: TextStyle(
                  fontSize: 9,
                  color:    Colors.grey.shade400,
                  fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis),
        ]),
      );
}

class _LocCard extends StatelessWidget {
  final Position? pos;
  final String? locName;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  const _LocCard(
      {required this.pos,     required this.locName,
       required this.loading, required this.error,
       required this.onRetry});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: loading ? null : onRetry,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _deco(),
          child: Row(children: [
            Icon(Icons.location_on_rounded,
                color: pos != null ? Colors.red : Colors.grey, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: loading
                  ? const Text('Fetching coordinates…')
                  : error != null
                      ? Text(error!,
                          style: const TextStyle(color: Colors.red))
                      : Text(
                          locName ??
                              'Coords: ${pos!.latitude.toStringAsFixed(4)}, '
                                  '${pos!.longitude.toStringAsFixed(4)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      );
}

class _NodeCard extends StatelessWidget {
  final String title, subtitle, status, valueLabel, value,
               rawMag, threshold, shaking, online, uptime, lastSeen;
  const _NodeCard({
    super.key,
    required this.title,      required this.subtitle,
    required this.status,     required this.valueLabel,
    required this.value,      required this.rawMag,
    required this.threshold,  required this.shaking,
    required this.online,     required this.uptime,
    required this.lastSeen,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: _deco(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: online == 'true'
                    ? Colors.green.shade100
                    : Colors.red.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                online == 'true' ? 'ONLINE' : 'OFFLINE',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: online == 'true'
                        ? Colors.green.shade800
                        : Colors.red.shade800),
              ),
            ),
          ]),
          const Divider(height: 24),
          GridView.count(
            crossAxisCount:  2,
            shrinkWrap:      true,
            physics:         const NeverScrollableScrollPhysics(),
            childAspectRatio: 2.8,
            crossAxisSpacing: 10,
            mainAxisSpacing:  10,
            children: [
              _sub('Status', status,
                  isAlertStatus(status)
                      ? Colors.red
                      : status.toLowerCase().contains('vib')
                          ? Colors.orange
                          : Colors.green),
              _sub(valueLabel, value, Colors.black),
              _sub('Raw Magnitude', rawMag, Colors.black),
              _sub('Threshold', threshold, Colors.black),
              _sub('Shaking',
                  shaking == 'true' ? 'YES' : 'NO',
                  shaking == 'true' ? Colors.orange : Colors.black),
              _sub('Uptime', uptime, Colors.black),
            ],
          ),
          const Divider(height: 24),
          Row(children: [
            const Icon(Icons.access_time_rounded,
                size: 14, color: Colors.grey),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Last Sync: $lastSeen',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        ]),
      );

  Widget _sub(String l, String v, Color c) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(l,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        Text(v,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: c,
                fontFamily: 'monospace')),
      ]);
}

class _Graph extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  const _Graph({required this.events});
  @override
  Widget build(BuildContext context) {
    final vals = events
        .map((e) => safeDouble(
            e['acceleration'] ?? e['delta'] ?? e['accel'], 0.0))
        .toList();
    if (vals.isEmpty) {
      return Container(
        height: 160,
        decoration: _deco(),
        child: const Center(
            child: Text('No confirmed detections yet',
                style: TextStyle(color: Colors.grey))),
      );
    }
    final dots = <FlSpot>[
      for (int i = 0; i < vals.length; i++) FlSpot(i.toDouble(), vals[i])
    ];
    return Container(
      height:  180,
      padding: const EdgeInsets.fromLTRB(10, 20, 20, 10),
      decoration: _deco(),
      child: LineChart(LineChartData(
        gridData:   const FlGridData(show: false),
        titlesData: const FlTitlesData(
          topTitles:    AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:  AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            axisNameWidget:
                Text('Event Sequence', style: TextStyle(fontSize: 10)),
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        borderData:   FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots:        dots,
            isCurved:     true,
            barWidth:     3,
            color:        Colors.red,
            dotData:      const FlDotData(show: true),
            belowBarData: BarAreaData(
                show: true, color: Colors.red.withAlpha(20)),
          ),
        ],
      )),
    );
  }
}

class _DndBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _DndBanner({required this.onTap});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color:        Colors.amber.shade50,
          borderRadius: BorderRadius.circular(16),
          border:       Border.all(color: Colors.amber.shade300),
        ),
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const Icon(Icons.do_not_disturb_off_rounded, color: Colors.amber),
          const SizedBox(width: 12),
          const Expanded(
              child: Text('Allow DND override for critical alerts.')),
          TextButton(onPressed: onTap, child: const Text('Enable')),
        ]),
      );
}

class _SecTitle extends StatelessWidget {
  final String t;
  const _SecTitle(this.t);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
      );
}

BoxDecoration _deco() => BoxDecoration(
      color:        Colors.white,
      borderRadius: BorderRadius.circular(18),
      boxShadow: [
        BoxShadow(
            color:     Colors.black.withAlpha(10),
            blurRadius: 10,
            offset:    const Offset(0, 4)),
      ],
    );