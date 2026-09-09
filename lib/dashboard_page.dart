import 'ui/reference_energy.dart';
import 'ui/home_scenes.dart';
import 'ui/smart_home_design.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'ble_service.dart';
import 'auth_service.dart';
import 'app_logger.dart';
import 'app_constants.dart';
import 'assistant_identity.dart';
import 'assistant_name_store.dart';
import 'ellie/ellie_assistant_sheet.dart';
import 'room_image_store.dart';
import 'widgets/room_photo_card.dart';

// ────────────────────────────────────────────────────────────
// 0. THEME MANAGEMENT
// ────────────────────────────────────────────────────────────
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);

// Nav index lives in a provider so theme changes don't reset it
final selectedNavIndexProvider = StateProvider<int>((ref) => 0);

// Bump this value after adding/editing/removing rooms or devices.
// HomeContent is keyed from it, so the dashboard reloads immediately.
final dashboardRefreshTickProvider = StateProvider<int>((ref) => 0);

// In-app notification center. This is intentionally local/in-app so it works
// without adding push-notification dependencies.
class AppNotificationItem {
  final String id;
  final String key;
  final String title;
  final String message;
  final DateTime createdAt;
  final IconData icon;
  final Color color;
  final bool read;

  const AppNotificationItem({
    required this.id,
    required this.key,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.icon,
    required this.color,
    this.read = false,
  });

  AppNotificationItem copyWith({bool? read}) => AppNotificationItem(
    id: id,
    key: key,
    title: title,
    message: message,
    createdAt: createdAt,
    icon: icon,
    color: color,
    read: read ?? this.read,
  );
}

class AppNotificationsController
    extends StateNotifier<List<AppNotificationItem>> {
  AppNotificationsController() : super(const []);

  void push({
    required String key,
    required String title,
    required String message,
    required IconData icon,
    required Color color,
    Duration suppressFor = const Duration(seconds: 45),
  }) {
    final now = DateTime.now();
    final recentDuplicate = state.any(
      (item) => item.key == key && now.difference(item.createdAt) < suppressFor,
    );
    if (recentDuplicate) return;

    final item = AppNotificationItem(
      id: '${key}_${now.microsecondsSinceEpoch}',
      key: key,
      title: title,
      message: message,
      createdAt: now,
      icon: icon,
      color: color,
    );

    state = [item, ...state].take(80).toList(growable: false);
  }

  void markAllRead() {
    state = [for (final item in state) item.copyWith(read: true)];
  }

  void clearAll() {
    state = const [];
  }
}

final appNotificationsProvider =
    StateNotifierProvider<
      AppNotificationsController,
      List<AppNotificationItem>
    >((ref) => AppNotificationsController());

String _timeAgo(DateTime date) {
  final diff = DateTime.now().difference(date);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return '${diff.inDays} d ago';
}

final lightTheme = HomeDesign.theme(Brightness.light);
final darkTheme = HomeDesign.theme(Brightness.dark);

// ────────────────────────────────────────────────────────────
// 1. DESIGN TOKENS
// ────────────────────────────────────────────────────────────
class _DT {
  static const purple = HomeDesign.blue;
  static const green = Color(0xFF4DFFA0);
  static const amber = Color(0xFFFFB347);
  static const blue = HomeDesign.cyan;
  static const red = Color(0xFFFF5252);
  static const espConnected = Color(0xFF4DFFA0);
}

// ────────────────────────────────────────────────────────────
// 2. RESPONSIVE HELPER
// ────────────────────────────────────────────────────────────
class ResponsiveHelper {
  static bool isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;

  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1200;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1200;

  static double getPadding(BuildContext context) {
    if (isDesktop(context)) return 40.0;
    if (isTablet(context)) return 30.0;
    return 20.0;
  }

  static int getGridColumns(BuildContext context) {
    if (isDesktop(context)) return 4;
    if (isTablet(context)) return 3;
    return 2;
  }
}

// ────────────────────────────────────────────────────────────
// 3. CACHED HTTP SERVICE
// ────────────────────────────────────────────────────────────
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  final Map<String, _CacheEntry> _cache = {};
  final Duration _ttl = const Duration(seconds: 3);

  void set(String key, dynamic data) {
    _cache[key] = _CacheEntry(data, DateTime.now().add(_ttl));
  }

  dynamic get(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiry)) {
      _cache.remove(key);
      return null;
    }
    return entry.data;
  }

  void clear() => _cache.clear();
}

class _CacheEntry {
  final dynamic data;
  final DateTime expiry;
  _CacheEntry(this.data, this.expiry);
}

// ────────────────────────────────────────────────────────────
// 4. ESP32 DEVICE MANAGEMENT SERVICE (FIXED)
// ────────────────────────────────────────────────────────────
class ESP32DeviceService {
  final String esp32Ip;
  final BleService bleService;

  ESP32DeviceService(this.esp32Ip, this.bleService);

  Map<String, dynamic>? _devicesFromBleCache() {
    if (!bleService.isConnected) return null;
    final bleDevices = bleService.devices
        .map((device) => Map<String, dynamic>.from(device))
        .toList();
    return {'devices': bleDevices};
  }

  Future<Map<String, dynamic>?> _tryGetDevicesFromBle() async {
    if (!bleService.isConnected) return null;
    try {
      await bleService.refreshDevices().timeout(AppConfig.mediumTimeout);
      return _devicesFromBleCache();
    } catch (e) {
      logDebug('BLE device list unavailable: $e');
      return _devicesFromBleCache();
    }
  }

  Future<Map<String, dynamic>?> _tryGetDevicesFromLocalHttp() async {
    try {
      final response = await http
          .get(
            Uri.parse('http://$esp32Ip/api/devices'),
            headers: const {'Cache-Control': 'no-cache'},
          )
          .timeout(AppConfig.shortTimeout);

      if (response.statusCode != 200 || response.body.isEmpty) return null;
      final data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return data.cast<String, dynamic>();
    } catch (e) {
      logDebug('Local device list unavailable: $e');
    }
    return null;
  }

  // Read devices. When Bluetooth backup is connected, prefer the ESP32 local
  // BLE device list so rooms/devices still appear when the phone has no internet.
  Future<Map<String, dynamic>> getDevices() async {
    // The ESP32 local API is the authoritative live state whenever it is
    // reachable. A previously cached BLE list can be stale and was causing the
    // dashboard to jump back to the old value after a successful toggle.
    Map<String, dynamic>? fastResult = await _tryGetDevicesFromLocalHttp();
    fastResult ??= await _tryGetDevicesFromBle();

    final bleCached = _devicesFromBleCache();
    if (fastResult == null &&
        bleCached != null &&
        (bleCached['devices'] as List).isNotEmpty) {
      fastResult = bleCached;
    }

    Map<String, dynamic> firebaseResult = {'devices': <Map<String, dynamic>>[]};

    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final user = FirebaseAuth.instance.currentUser;

      if (user != null) {
        final response = await http
            .get(
              Uri.parse('$databaseUrl/smartHome/${user.uid}/devices.json'),
              headers: {'Cache-Control': 'no-cache'},
            )
            .timeout(AppConfig.mediumTimeout);

        if (response.statusCode == 200 &&
            response.body.isNotEmpty &&
            response.body != 'null') {
          final dynamic data = jsonDecode(response.body);
          if (data is Map) {
            final firebaseDevices = <Map<String, dynamic>>[];
            data.forEach((key, value) {
              if (value is Map) {
                final device = value.cast<String, dynamic>();
                device['id'] ??= key.toString();
                firebaseDevices.add(device);
              }
            });
            firebaseResult = {'devices': firebaseDevices};
          }
        }
      }
    } catch (e) {
      logDebug('Firebase device list unavailable: $e');
    }

    if (fastResult == null) return firebaseResult;

    // Merge Firebase metadata with the fast ESP/BLE state. This keeps legacy
    // devices visible so the user can assign P0..P7, while local state wins.
    final merged = <String, Map<String, dynamic>>{};

    for (final raw in firebaseResult['devices'] as List? ?? const []) {
      if (raw is! Map) continue;
      final device = raw.cast<String, dynamic>();
      final id = (device['id'] ?? '').toString();
      if (id.isNotEmpty) merged[id] = Map<String, dynamic>.from(device);
    }

    for (final raw in fastResult['devices'] as List? ?? const []) {
      if (raw is! Map) continue;
      final device = raw.cast<String, dynamic>();
      final id = (device['id'] ?? '').toString();
      if (id.isEmpty) continue;
      merged[id] = {...?merged[id], ...device};
    }

    return {'devices': merged.values.toList()};
  }

  Future<List<Map<String, dynamic>>> getIoModules() async {
    List<Map<String, dynamic>> parseModules(dynamic raw) {
      final result = <Map<String, dynamic>>[];
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is! Map) return;
          final item = Map<String, dynamic>.from(value);
          item['id'] ??= key.toString();
          item['name'] ??= item['id'];
          item['busId'] ??= 0;
          item['address'] ??= 32;
          item['channels'] ??= 8;
          item['enabled'] ??= true;
          result.add(item);
        });
      }
      result.sort(
        (a, b) => a['name'].toString().compareTo(b['name'].toString()),
      );
      return result.where((m) => m['enabled'] != false).toList();
    }

    try {
      final response = await http
          .get(
            Uri.parse('http://$esp32Ip/api/io/modules'),
            headers: const {'Cache-Control': 'no-cache'},
          )
          .timeout(AppConfig.shortTimeout);
      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final modules = parseModules(decoded['ioModules']);
          if (modules.isNotEmpty) return modules;
        }
      }
    } catch (e) {
      logDebug('Local I/O module list unavailable: $e');
    }

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final response = await http
            .get(
              Uri.parse(
                '${AppConfig.databaseUrl}/smartHome/$uid/hardware/ioModules.json',
              ),
              headers: const {'Cache-Control': 'no-cache'},
            )
            .timeout(AppConfig.mediumTimeout);
        if (response.statusCode == 200 && response.body != 'null') {
          final modules = parseModules(jsonDecode(response.body));
          if (modules.isNotEmpty) return modules;
        }
      }
    } catch (e) {
      logDebug('Cloud I/O module list unavailable: $e');
    }

    return <Map<String, dynamic>>[
      {
        'id': 'io_1',
        'name': 'I/O Module 1',
        'busId': 0,
        'address': 32,
        'channels': 8,
        'enabled': true,
      },
    ];
  }

  // Add a device by assigning a channel inside a selected I/O module.
  Future<bool> addDevice({
    required String name,
    required int type,
    required String moduleId,
    required int channel,
    required String room,
  }) async {
    try {
      final usedChannels = await getUsedChannels(moduleId: moduleId);
      if (usedChannels.contains(channel)) {
        logDebug('$moduleId/P$channel is already used by another device.');
        return false;
      }

      final String uid = FirebaseAuth.instance.currentUser!.uid;
      final String id = 'dev_${DateTime.now().millisecondsSinceEpoch}';
      final deviceData = <String, dynamic>{
        'id': id,
        'name': name,
        'type': type,
        'moduleId': moduleId,
        'expanderId': moduleId,
        'channel': channel,
        'room': room,
        'state': false,
        'enabled': true,
      };

      // Save to Firebase first so cloud state remains the source of truth.
      final response = await http
          .put(
            Uri.parse(
              '${AppConfig.databaseUrl}/smartHome/$uid/devices/$id.json',
            ),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(deviceData),
          )
          .timeout(AppConfig.mediumTimeout);

      if (response.statusCode != 200) return false;

      // Apply the new device directly to the running ESP32. Previously the app
      // only wrote Firebase and depended on a later SSE/full sync, so the new
      // PCF8574 output sometimes did not exist locally until an ESP32 restart.
      bool appliedLocally = false;
      try {
        final localResponse = await http
            .post(
              Uri.parse('http://$esp32Ip/api/devices/add'),
              body: {
                'id': id,
                'name': name,
                'type': '$type',
                'moduleId': moduleId,
                'channel': '$channel',
                'room': room,
              },
            )
            .timeout(AppConfig.mediumTimeout);
        appliedLocally =
            localResponse.statusCode >= 200 && localResponse.statusCode < 300;
      } catch (e) {
        logDebug('Direct ESP32 device add unavailable: $e');
      }

      // Compatibility fallback for an ESP32 that has the sync endpoint but not
      // the new ID-aware add endpoint.
      if (!appliedLocally) {
        try {
          final syncResponse = await http
              .get(
                Uri.parse('http://$esp32Ip/api/sync'),
                headers: const {'Cache-Control': 'no-cache'},
              )
              .timeout(AppConfig.mediumTimeout);
          appliedLocally =
              syncResponse.statusCode >= 200 && syncResponse.statusCode < 300;
        } catch (e) {
          logDebug('Local ESP32 sync unavailable: $e');
        }
      }

      // BLE can ask the ESP32 to pull the newly-created Firebase device when the
      // phone is not on the same LAN.
      if (!appliedLocally && bleService.isConnected) {
        try {
          appliedLocally = await bleService.requestDeviceSync();
        } catch (e) {
          logDebug('BLE device sync unavailable: $e');
        }
      }

      if (bleService.isConnected) {
        await Future.delayed(const Duration(milliseconds: 120));
        await bleService.refreshDevices().catchError((_) {});
      }

      CacheService().clear();
      return true;
    } catch (e) {
      logDebug('Error adding device: $e');
      return false;
    }
  }

  Future<bool> editDeviceOutput({
    required String id,
    required String moduleId,
    required int newChannel,
  }) async {
    try {
      final usedChannels = await getUsedChannels(
        moduleId: moduleId,
        excludingDeviceId: id,
      );
      if (usedChannels.contains(newChannel)) return false;

      final String uid = FirebaseAuth.instance.currentUser!.uid;
      final body = {
        'moduleId': moduleId,
        'expanderId': moduleId,
        'channel': newChannel,
      };
      final response = await http
          .patch(
            Uri.parse(
              '${AppConfig.databaseUrl}/smartHome/$uid/devices/$id.json',
            ),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(AppConfig.mediumTimeout);

      if (response.statusCode == 200) {
        try {
          await http
              .post(
                Uri.parse('http://$esp32Ip/api/devices/output'),
                body: {
                  'id': id,
                  'moduleId': moduleId,
                  'channel': '$newChannel',
                },
              )
              .timeout(AppConfig.shortTimeout);
        } catch (_) {
          if (bleService.isConnected) {
            await bleService
                .editOutput(id, moduleId, newChannel)
                .catchError((_) => false);
          }
        }
      }
      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error editing I/O output: $e');
      return false;
    }
  }

  // Use exactly one command path. Racing local HTTP and BLE sent duplicate
  // commands and let one path keep a stale cache, which made the UI bounce and
  // could replay old cloud state. Prefer local Wi-Fi, then BLE, then Firebase.
  Future<bool> controlDevice({required String id, required bool state}) async {
    if (await _tryLocalControl(id: id, state: state)) return true;
    if (bleService.isConnected && await _tryBleControl(id: id, state: state)) {
      return true;
    }
    return _controlDeviceViaFirebase(id: id, state: state);
  }

  Future<bool> _tryBleControl({required String id, required bool state}) async {
    if (!bleService.isConnected) return false;
    try {
      return await bleService
          .controlDevice(id: id, state: state)
          .timeout(AppConfig.bleControlTimeout);
    } catch (e) {
      logDebug('BLE control skipped: $e');
      return false;
    }
  }

  Future<bool> _tryLocalControl({
    required String id,
    required bool state,
  }) async {
    try {
      final localResponse = await http
          .post(
            Uri.parse('http://$esp32Ip/api/devices/control'),
            headers: const {'Cache-Control': 'no-cache'},
            body: {'id': id, 'state': state ? 'true' : 'false'},
          )
          .timeout(AppConfig.localControlTimeout);
      return localResponse.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _controlDeviceViaFirebase({
    required String id,
    required bool state,
  }) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http
          .patch(
            Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'state': state}),
          )
          .timeout(AppConfig.firebaseControlTimeout);

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error controlling device: $e');
      return false;
    }
  }

  // Remove device via Firebase
  Future<bool> removeDevice(String id) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http
          .delete(Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'))
          .timeout(AppConfig.shortTimeout);

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error removing device: $e');
      return false;
    }
  }

  // Save rooms to Firebase
  Future<bool> saveRooms(List<String> rooms) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http
          .put(
            Uri.parse('$databaseUrl/smartHome/$uid/rooms.json'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(rooms),
          )
          .timeout(AppConfig.mediumTimeout);

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error saving rooms: $e');
      return false;
    }
  }

  Future<bool> renameRoomInDevices({
    required String oldRoom,
    required String newRoom,
  }) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final devicesResult = await getDevices();
      final devices = devicesResult['devices'] as List? ?? [];
      bool ok = true;

      for (final device in devices) {
        if (device is Map &&
            device['room'] == oldRoom &&
            device['id'] != null) {
          final id = device['id'].toString();
          final response = await http
              .patch(
                Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'room': newRoom}),
              )
              .timeout(AppConfig.mediumTimeout);
          ok = ok && response.statusCode == 200;
        }
      }

      return ok;
    } catch (e) {
      logDebug('Error renaming room in devices: $e');
      return false;
    }
  }

  List<String> _roomsFromDeviceList(List<Map<String, dynamic>> devices) {
    final rooms = <String>{};
    for (final device in devices) {
      final room = device['room']?.toString().trim() ?? '';
      if (room.isNotEmpty) rooms.add(room);
    }
    return rooms.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  // Get rooms from Firebase. Important: do NOT invent default rooms.
  // When Bluetooth backup is connected, derive rooms from the ESP32 local device list.
  Future<List<String>> getRooms() async {
    if (bleService.isConnected) {
      final bleRoomsCached = _roomsFromDeviceList(bleService.devices);
      if (bleRoomsCached.isNotEmpty) return bleRoomsCached;
      try {
        await bleService.refreshDevices().timeout(AppConfig.shortTimeout);
      } catch (e) {
        logDebug('BLE room refresh skipped: $e');
      }
      final bleRooms = _roomsFromDeviceList(bleService.devices);
      if (bleRooms.isNotEmpty) return bleRooms;
    }

    List<String> normalizeRooms(dynamic data) {
      final Set<String> rooms = {};

      if (data is List) {
        for (final item in data) {
          final room = item?.toString().trim() ?? '';
          if (room.isNotEmpty) rooms.add(room);
        }
      } else if (data is Map) {
        for (final item in data.values) {
          final room = item?.toString().trim() ?? '';
          if (room.isNotEmpty) rooms.add(room);
        }
      }

      final sorted = rooms.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return sorted;
    }

    try {
      final localResponse = await http
          .get(
            Uri.parse('http://$esp32Ip/api/rooms'),
            headers: const {'Cache-Control': 'no-cache'},
          )
          .timeout(AppConfig.shortTimeout);
      if (localResponse.statusCode == 200 && localResponse.body.isNotEmpty) {
        final rooms = normalizeRooms(jsonDecode(localResponse.body)['rooms']);
        if (rooms.isNotEmpty) return rooms;
      }
    } catch (e) {
      logDebug('Local rooms unavailable: $e');
    }

    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http
          .get(
            Uri.parse('$databaseUrl/smartHome/$uid/rooms.json'),
            headers: {'Cache-Control': 'no-cache'},
          )
          .timeout(AppConfig.shortTimeout);

      if (response.statusCode == 200 &&
          response.body.isNotEmpty &&
          response.body != 'null') {
        final rooms = normalizeRooms(jsonDecode(response.body));
        if (rooms.isNotEmpty) return rooms;
      }

      // Migration fallback only: if old devices already have room names but no
      // /rooms node exists yet, show those rooms. Do not create fake defaults.
      final devicesResponse = await http
          .get(
            Uri.parse('$databaseUrl/smartHome/$uid/devices.json'),
            headers: {'Cache-Control': 'no-cache'},
          )
          .timeout(AppConfig.shortTimeout);

      if (devicesResponse.statusCode == 200 &&
          devicesResponse.body.isNotEmpty &&
          devicesResponse.body != 'null') {
        final dynamic data = jsonDecode(devicesResponse.body);
        final Set<String> rooms = {};
        if (data is Map) {
          data.forEach((_, value) {
            if (value is Map && value['room'] != null) {
              final room = value['room'].toString().trim();
              if (room.isNotEmpty) rooms.add(room);
            }
          });
        }
        final roomsList = rooms.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (roomsList.isNotEmpty) {
          await saveRooms(roomsList);
          return roomsList;
        }
      }

      return [];
    } catch (e) {
      logDebug('Error getting rooms: $e');
      return [];
    }
  }

  Future<Set<int>> getUsedChannels({
    required String moduleId,
    String? excludingDeviceId,
  }) async {
    final result = await getDevices();
    final devices = result['devices'] as List? ?? [];
    final used = <int>{};
    for (final device in devices) {
      if (device is! Map) continue;
      final id = device['id']?.toString();
      if (excludingDeviceId != null && id == excludingDeviceId) continue;
      final deviceModule =
          (device['moduleId'] ?? device['expanderId'] ?? 'io_1').toString();
      if (deviceModule != moduleId) continue;
      final raw = device['channel'];
      final channel = raw is num
          ? raw.toInt()
          : int.tryParse(raw?.toString() ?? '');
      if (channel != null) used.add(channel);
    }
    return used;
  }

  Future<List<int>> getSelectableChannels({
    required String moduleId,
    String? excludingDeviceId,
    int? currentChannel,
  }) async {
    List<int> scanned = const [];
    Set<int> used = const {};
    try {
      scanned = await getAvailableChannels(moduleId);
    } catch (_) {}
    try {
      used = await getUsedChannels(
        moduleId: moduleId,
        excludingDeviceId: excludingDeviceId,
      );
    } catch (_) {
      used = <int>{};
      for (final device in bleService.devices) {
        final id = device['id']?.toString();
        if (excludingDeviceId != null && id == excludingDeviceId) continue;
        final deviceModule =
            (device['moduleId'] ?? device['expanderId'] ?? 'io_1').toString();
        if (deviceModule != moduleId) continue;
        final raw = device['channel'];
        final channel = raw is num
            ? raw.toInt()
            : int.tryParse(raw?.toString() ?? '');
        if (channel != null) used.add(channel);
      }
    }

    final all = <int>{...List<int>.generate(8, (i) => i), ...scanned};
    if (currentChannel != null && currentChannel >= 0 && currentChannel < 8)
      all.add(currentChannel);
    return all
        .where(
          (channel) => !used.contains(channel) || channel == currentChannel,
        )
        .toList()
      ..sort();
  }

  Future<List<int>> getAvailableChannels(String moduleId) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              'http://$esp32Ip/api/channels?moduleId=${Uri.encodeQueryComponent(moduleId)}',
            ),
          )
          .timeout(AppConfig.shortTimeout);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final available = data['available'] as List? ?? [];
        return available
            .whereType<Map>()
            .map((e) => (e['channel'] as num).toInt())
            .toList();
      }
    } catch (e) {
      logDebug('I/O channel scan failed: $e');
    }
    return List<int>.generate(8, (index) => index);
  }

  Future<List<Map<String, dynamic>>> getDeviceTypes() async {
    try {
      final response = await http
          .get(Uri.parse('http://$esp32Ip/api/devicetypes'))
          .timeout(AppConfig.shortTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['types'] as List? ?? [])
            .map((e) => e as Map<String, dynamic>)
            .toList();
      }
      return [
        {'type': 0, 'name': 'Light', 'icon': 'lightbulb'},
        {'type': 1, 'name': 'Fan', 'icon': 'fan'},
        {'type': 2, 'name': 'Switch', 'icon': 'power'},
        {'type': 3, 'name': 'Socket', 'icon': 'power_plug'},
      ];
    } catch (e) {
      return [
        {'type': 0, 'name': 'Light', 'icon': 'lightbulb'},
        {'type': 1, 'name': 'Fan', 'icon': 'fan'},
        {'type': 2, 'name': 'Switch', 'icon': 'power'},
        {'type': 3, 'name': 'Socket', 'icon': 'power_plug'},
      ];
    }
  }
}

// ────────────────────────────────────────────────────────────
// 5. ESP32 IP PROVIDER
// ────────────────────────────────────────────────────────────
final userEsp32CodeProvider = FutureProvider<String?>((ref) async {
  try {
    final authService = await ref.watch(authServiceProvider.future);
    final user = authService.currentUser;

    if (user != null) {
      final String databaseUrl = AppConfig.databaseUrl;
      final response = await http
          .get(
            Uri.parse('$databaseUrl/users/${user.uid}/esp32Code.json'),
            headers: {'Cache-Control': 'no-cache'},
          )
          .timeout(AppConfig.shortTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data as String?;
      }
    }
  } catch (e) {
    // Phone may have no internet while Bluetooth backup is connected.
    // Do not break the Settings page with a raw SocketException.
    logDebug('ESP32 code lookup unavailable offline: $e');
  }
  return null;
});

final esp32IpProvider = FutureProvider<String>((ref) async {
  if (AppConfig.esp32IpOverride.isNotEmpty) {
    return AppConfig.esp32IpOverride;
  }

  final bleService = ref.read(bleServiceProvider);
  if (bleService.isConnected) {
    try {
      await bleService.readControllerStatus();
      final bleIp = bleService.controllerIp;
      if (bleIp != null && bleIp.isNotEmpty) return bleIp;
    } catch (e) {
      logDebug('ESP32 IP unavailable from BLE status: $e');
    }
  }

  final code = await ref.watch(userEsp32CodeProvider.future);
  final authService = await ref.watch(authServiceProvider.future);
  final user = authService.currentUser;

  if (code == null || code.isEmpty || user == null) {
    return AppConfig.fallbackEsp32Ip;
  }

  logDebug('🔎 Looking up IP for ESP32 Code: $code');

  final String databaseUrl = AppConfig.databaseUrl;

  try {
    final response = await http
        .get(
          Uri.parse('$databaseUrl/esp_public/$code/status.json'),
          headers: {'Cache-Control': 'no-cache'},
        )
        .timeout(AppConfig.mediumTimeout);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data != null && data['ip'] != null) {
        return data['ip'] as String;
      }
    }
  } catch (e) {
    logDebug('Error fetching IP from esp_public: $e');
  }

  try {
    final response = await http
        .get(
          Uri.parse('$databaseUrl/smartHome/${user.uid}/status.json'),
          headers: {'Cache-Control': 'no-cache'},
        )
        .timeout(AppConfig.shortTimeout);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data != null && data['uniqueCode'] == code) {
        return data['ip'] ?? AppConfig.fallbackEsp32Ip;
      }
    }
  } catch (e) {
    logDebug('Error fetching IP from user node: $e');
  }

  return AppConfig.fallbackEsp32Ip;
});

Future<String> _resolveAssistantEsp32Ip(WidgetRef ref) async {
  if (AppConfig.esp32IpOverride.isNotEmpty) {
    return AppConfig.esp32IpOverride;
  }

  final bleService = ref.read(bleServiceProvider);
  if (bleService.isConnected) {
    try {
      await bleService.readControllerStatus();
      final bleIp = bleService.controllerIp;
      if (bleIp != null && bleIp.isNotEmpty) return bleIp;
    } catch (e) {
      logDebug('Assistant IP unavailable from BLE status: $e');
    }
  }

  try {
    return await ref.read(esp32IpProvider.future);
  } catch (e) {
    logDebug('Assistant IP provider unavailable: $e');
    return AppConfig.fallbackEsp32Ip;
  }
}

final esp32DeviceServiceProvider = FutureProvider<ESP32DeviceService>((
  ref,
) async {
  final ip = await ref.watch(esp32IpProvider.future);
  final bleService = ref.read(bleServiceProvider);
  return ESP32DeviceService(ip, bleService);
});

// ────────────────────────────────────────────────────────────
// 6. HTTP POLLING SERVICE WITH CACHING
// ────────────────────────────────────────────────────────────
final databaseUrlProvider = Provider((ref) => AppConfig.databaseUrl);

int _asEpochSeconds(dynamic value) {
  int parsed = 0;
  if (value is int) {
    parsed = value;
  } else if (value is num) {
    parsed = value.toInt();
  } else {
    parsed = int.tryParse(value?.toString() ?? '') ?? 0;
  }
  // Accept either seconds or milliseconds from older database records.
  if (parsed > 100000000000) parsed ~/= 1000;
  return parsed;
}

final httpDataProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final url = ref.watch(databaseUrlProvider);
  final authService = await ref.watch(authServiceProvider.future);
  final user = authService.currentUser;
  final cache = CacheService();

  final processedData = <String, dynamic>{
    'sensors': <String, dynamic>{
      'temperature': null,
      'humidity': null,
      'flame': false,
    },
    'lights': <String, dynamic>{},
    'status': <String, dynamic>{'online': false},
  };

  if (user == null) return processedData;

  final cacheKey = 'smartHome_${user.uid}';
  final cached = cache.get(cacheKey);
  if (cached != null) return Map<String, dynamic>.from(cached as Map);

  // Read cloud data, but do not let a Firebase timeout automatically mean that
  // the ESP32 is offline. Local HTTP and BLE are independent control paths.
  try {
    final response = await http
        .get(
          Uri.parse('$url/smartHome/${user.uid}.json'),
          headers: const {'Cache-Control': 'no-cache'},
        )
        .timeout(AppConfig.mediumTimeout);

    if (response.statusCode == 200 &&
        response.body.isNotEmpty &&
        response.body != 'null') {
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final jsonData = decoded.cast<String, dynamic>();
        final sensorsNode = jsonData['sensors'];
        if (sensorsNode is Map) {
          processedData['sensors'] = Map<String, dynamic>.from(sensorsNode);
        } else {
          processedData['sensors'] = <String, dynamic>{
            'temperature': jsonData['temperature'],
            'humidity': jsonData['humidity'],
            'flame': jsonData['flame'] ?? false,
          };
        }
        if (jsonData['lights'] is Map) {
          processedData['lights'] = Map<String, dynamic>.from(
            jsonData['lights'] as Map,
          );
        }
        if (jsonData['status'] is Map) {
          processedData['status'] = Map<String, dynamic>.from(
            jsonData['status'] as Map,
          );
        }
      }
    }
  } catch (e) {
    logDebug('Firebase dashboard read unavailable: $e');
  }

  final status = Map<String, dynamic>.from(
    processedData['status'] as Map? ?? const {},
  );
  final lastSeen = _asEpochSeconds(status['lastSeen']);
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final heartbeatFresh = lastSeen > 0 && (now - lastSeen).abs() < 120;
  status['online'] = status['online'] == true && heartbeatFresh;

  // The local ESP32 status endpoint is the strongest proof that the board is
  // actually running. It prevents a rejected/stale Firebase heartbeat from
  // displaying “ESP offline” while physical control still works.
  try {
    final ip = await ref.watch(esp32IpProvider.future);
    if (ip.isNotEmpty) {
      final localResponse = await http
          .get(
            Uri.parse('http://$ip/api/wifi/status'),
            headers: const {'Cache-Control': 'no-cache'},
          )
          .timeout(AppConfig.shortTimeout);
      if (localResponse.statusCode == 200 && localResponse.body.isNotEmpty) {
        final dynamic decoded = jsonDecode(localResponse.body);
        if (decoded is Map) {
          final local = decoded.cast<String, dynamic>();
          status.addAll(local);
          status['online'] =
              local['online'] == true ||
              (local['ip']?.toString().isNotEmpty ?? false);
          status['source'] = 'local';
        }
      }
    }
  } catch (e) {
    logDebug('Local ESP32 status unavailable: $e');
  }

  processedData['status'] = status;
  cache.set(cacheKey, processedData);
  return processedData;
});

// ────────────────────────────────────────────────────────────
// 7. BLE + HTTP MERGED DATA PROVIDER
// ────────────────────────────────────────────────────────────
final smartHomeDataProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  final controller = StreamController<Map<String, dynamic>>();
  late StreamSubscription bleStatusSub;
  Timer? httpTimer;
  final cache = CacheService();

  final authService = ref.watch(authServiceProvider).requireValue;
  final user = authService.currentUser;

  Map<String, dynamic> currentData = {
    'sensors': {'temperature': null, 'humidity': null, 'flame': false},
    'lights': {},
    'status': {'online': false},
  };

  controller.add(Map.from(currentData));

  void updateFromBle() {
    if (bleService.isConnected) {
      currentData['sensors'] = {
        'temperature': bleService.temperature,
        'humidity': bleService.humidity,
        'flame': bleService.flameDetected,
      };
      currentData['lights'] = Map.from(bleService.lights);
      final status = Map<String, dynamic>.from(
        currentData['status'] as Map? ?? {},
      );
      status['online'] = true;
      status['ip'] = status['ip'] ?? 'BLE';
      status['ping'] = status['ping'] ?? 0;
      currentData['status'] = status;
      if (user != null) {
        cache.set('bleData_${user.uid}', currentData);
      }
      if (!controller.isClosed) controller.add(Map.from(currentData));
    }
  }

  Future<void> fetchHttpData() async {
    try {
      final httpData = await ref.read(httpDataProvider.future);
      if (!bleService.isConnected) {
        if (user != null) {
          final cachedBle = cache.get('bleData_${user.uid}');
          if (cachedBle != null) {
            currentData = Map<String, dynamic>.from(cachedBle as Map);
            currentData['status'] = httpData['status'] ?? currentData['status'];
            if (!controller.isClosed) controller.add(Map.from(currentData));
            return;
          }
        }
        currentData = httpData;
        if (!controller.isClosed) controller.add(Map.from(currentData));
      } else if (httpData.containsKey('status')) {
        final status = Map<String, dynamic>.from(
          httpData['status'] as Map? ?? {},
        );
        status['online'] = true;
        currentData['status'] = status;
        if (!controller.isClosed) controller.add(Map.from(currentData));
      }
    } catch (e) {
      if (!controller.isClosed && currentData.isNotEmpty) {
        controller.add(Map.from(currentData));
      }
    }
  }

  if (user != null) {
    final cachedData = cache.get('bleData_${user.uid}');
    if (cachedData != null) {
      currentData = Map<String, dynamic>.from(cachedData as Map);
      Future.microtask(() {
        if (!controller.isClosed) controller.add(Map.from(currentData));
      });
    }
  }

  bleStatusSub = bleService.statusStream.listen((status) {
    if (status == BleStatus.connected || status == BleStatus.dataUpdated) {
      updateFromBle();
    } else if (status == BleStatus.disconnected) {
      ref.invalidate(httpDataProvider);
    }
  });

  fetchHttpData();

  httpTimer = Timer.periodic(
    const Duration(seconds: 8),
    (_) => fetchHttpData(),
  );

  // Do not auto-open the browser Bluetooth chooser.
  // Bluetooth connection is now manual only, so cancelling the Web Bluetooth
  // popup cannot create red errors or trigger tab-switch glitches.

  ref.onDispose(() {
    bleStatusSub.cancel();
    httpTimer?.cancel();
    controller.close();
  });

  return controller.stream;
});

// ────────────────────────────────────────────────────────────
// 8. LIGHT TOGGLE SERVICE
// ────────────────────────────────────────────────────────────
final lightToggleProvider = Provider((ref) => LightToggleService(ref));

class LightToggleService {
  final Ref _ref;
  LightToggleService(this._ref);

  void _patchCache(String cacheKey, String room, bool value) {
    final cached = CacheService().get(cacheKey);
    if (cached == null) return;
    final updated = Map<String, dynamic>.from(cached as Map);
    final lights = Map<String, dynamic>.from(updated['lights'] ?? {});
    lights[room] = value;
    updated['lights'] = lights;
    CacheService().set(cacheKey, updated);
  }

  void _revertCache(String cacheKey, String room, bool originalValue) {
    _patchCache(cacheKey, room, originalValue);
  }

  Future<void> toggle(String room, bool value, BuildContext context) async {
    final bleService = _ref.read(bleServiceProvider);
    final url = _ref.read(databaseUrlProvider);
    final authService = _ref.watch(authServiceProvider).requireValue;
    final user = authService.currentUser;

    if (user == null) {
      if (context.mounted) {
        _showSnack(context, '❌ User not authenticated', color: _DT.red);
      }
      return;
    }

    final cacheKey = 'smartHome_${user.uid}';
    final bleCacheKey = 'bleData_${user.uid}';

    _patchCache(cacheKey, room, value);
    _patchCache(bleCacheKey, room, value);

    if (bleService.currentStatus == BleStatus.connected) {
      try {
        await bleService.setLightState(room, value);
        return;
      } catch (e) {
        if (context.mounted) {
          _showSnack(context, 'BLE error, trying Wi-Fi…', color: Colors.orange);
        }
      }
    }

    try {
      final response = await http
          .patch(
            Uri.parse('$url/smartHome/${user.uid}/lights.json'),
            body: jsonEncode({room: value}),
          )
          .timeout(AppConfig.firebaseControlTimeout);

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      _revertCache(cacheKey, room, !value);
      _revertCache(bleCacheKey, room, !value);
      if (context.mounted) {
        _showSnack(context, 'Failed to toggle light', color: _DT.red);
      }
      rethrow;
    }
  }
}

void _showSnack(
  BuildContext context,
  String msg, {
  Color color = Colors.white,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: color.withValues(alpha: 0.9),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 2),
    ),
  );
}

// ────────────────────────────────────────────────────────────
// 9. WALLPAPER BACKGROUND
// ────────────────────────────────────────────────────────────
class _WallpaperBackground extends StatelessWidget {
  const _WallpaperBackground({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => HomeBackground(child: child);
}

// ────────────────────────────────────────────────────────────
// 10. DASHBOARD PAGE
// ────────────────────────────────────────────────────────────
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage>
    with SingleTickerProviderStateMixin {
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = const [
      _HomeContentWrapper(),
      _EnergyScreen(),
      _AlertsScreen(),
      _SettingsScreen(),
    ];
  }

  Future<void> _manualRefresh() async {
    final bleService = ref.read(bleServiceProvider);
    if (bleService.isConnected) {
      await bleService.refreshDevices().catchError((_) {});
    }
    ref.invalidate(httpDataProvider);
    if (mounted) _showSnack(context, 'Refreshed ✓', color: _DT.green);
  }

  void _showQuickActionDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (context) => const _QuickActionDialog(),
    );
  }

  Future<void> _showEllieAssistant(String assistantName) async {
    final esp32Ip = await _resolveAssistantEsp32Ip(ref);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => EllieAssistantSheet(
        esp32BaseUri: Uri.parse('http://$esp32Ip'),
        assistantName: assistantName,
        bleService: ref.read(bleServiceProvider),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = ref.watch(selectedNavIndexProvider);
    final isDesktop = ResponsiveHelper.isDesktop(context);
    final assistantName =
        ref.watch(assistantNameProvider).asData?.value ?? defaultAssistantName;
    final unread = ref
        .watch(appNotificationsProvider)
        .where((n) => !n.read)
        .length;
    return Scaffold(
      body: _WallpaperBackground(
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              if (isDesktop)
                _DesktopSidebar(
                  selectedIndex: selectedIndex,
                  assistantName: assistantName,
                  onTap: (i) =>
                      ref.read(selectedNavIndexProvider.notifier).state = i,
                  onAdd: () => _showQuickActionDialog(context),
                  onAssistant: () =>
                      unawaited(_showEllieAssistant(assistantName)),
                ),
              Expanded(
                child: IndexedStack(index: selectedIndex, children: _pages),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: isDesktop
          ? null
          : HomeBackground(
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (selectedIndex == 0) ...[
                        HomeVoiceButton(
                          onPressed: () =>
                              unawaited(_showEllieAssistant(assistantName)),
                          label: 'Talk to $assistantName',
                        ),
                        const SizedBox(height: 10),
                      ],
                      HomeBottomNav(
                        index: selectedIndex,
                        unreadCount: unread,
                        onChanged: (i) =>
                            ref.read(selectedNavIndexProvider.notifier).state =
                                i,
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 11. PASSWORD DIALOG
// ────────────────────────────────────────────────────────────
class _PasswordDialog extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback? onCancel;

  const _PasswordDialog({required this.onSuccess, this.onCancel});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  bool _obscureText = true;
  String _errorMessage = '';

  void _verifyPassword() {
    if (_passwordController.text == '1234') {
      widget.onSuccess();
      Navigator.pop(context);
    } else {
      setState(() {
        _errorMessage = 'Incorrect password. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: Colors.transparent,
      child: _GCard(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _DT.purple.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.lock_rounded,
                color: _DT.purple,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter Password',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'This action requires admin password',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _passwordController,
              obscureText: _obscureText,
              decoration: InputDecoration(
                hintText: 'Enter password',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _DT.purple, width: 2),
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureText
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  onPressed: () => setState(() => _obscureText = !_obscureText),
                ),
                errorText: _errorMessage.isNotEmpty ? _errorMessage : null,
              ),
              onSubmitted: (_) => _verifyPassword(),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      widget.onCancel?.call();
                      Navigator.pop(context);
                    },
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _verifyPassword,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _DT.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'Verify',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }
}

// ────────────────────────────────────────────────────────────
// 12. EDIT PCF8574 CHANNEL DIALOG
// ────────────────────────────────────────────────────────────
class _EditChannelDialog extends ConsumerStatefulWidget {
  final String deviceId;
  final String deviceName;
  final String currentModuleId;
  final int currentChannel;

  const _EditChannelDialog({
    required this.deviceId,
    required this.deviceName,
    required this.currentModuleId,
    required this.currentChannel,
  });

  @override
  ConsumerState<_EditChannelDialog> createState() => _EditChannelDialogState();
}

class _EditChannelDialogState extends ConsumerState<_EditChannelDialog> {
  bool _loading = true;
  bool _saving = false;
  List<Map<String, dynamic>> _modules = const [];
  List<int> _channels = const [];
  late String _moduleId;
  int? _channel;

  @override
  void initState() {
    super.initState();
    _moduleId = widget.currentModuleId.isEmpty
        ? 'io_1'
        : widget.currentModuleId;
    _channel = widget.currentChannel >= 0 ? widget.currentChannel : null;
    _load();
  }

  Future<void> _load() async {
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final modules = await service.getIoModules();
    if (!modules.any((m) => m['id'].toString() == _moduleId) &&
        modules.isNotEmpty) {
      _moduleId = modules.first['id'].toString();
    }
    final channels = await service.getSelectableChannels(
      moduleId: _moduleId,
      excludingDeviceId: widget.deviceId,
      currentChannel: _moduleId == widget.currentModuleId
          ? widget.currentChannel
          : null,
    );
    if (!mounted) return;
    setState(() {
      _modules = modules;
      _channels = channels;
      if (!_channels.contains(_channel))
        _channel = _channels.isEmpty ? null : _channels.first;
      _loading = false;
    });
  }

  Future<void> _changeModule(String moduleId) async {
    setState(() {
      _moduleId = moduleId;
      _loading = true;
    });
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final channels = await service.getSelectableChannels(
      moduleId: moduleId,
      excludingDeviceId: widget.deviceId,
      currentChannel: moduleId == widget.currentModuleId
          ? widget.currentChannel
          : null,
    );
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _channel = channels.isEmpty ? null : channels.first;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_channel == null) return;
    setState(() => _saving = true);
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final ok = await service.editDeviceOutput(
      id: widget.deviceId,
      moduleId: _moduleId,
      newChannel: _channel!,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.read(dashboardRefreshTickProvider.notifier).state++;
      ref.invalidate(httpDataProvider);
      Navigator.pop(context, true);
      _showSnack(context, 'I/O output updated.', color: _DT.green);
    } else {
      _showSnack(
        context,
        'That module output is already assigned.',
        color: _DT.red,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Assign I/O Output'),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.deviceName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    value: _modules.any((m) => m['id'].toString() == _moduleId)
                        ? _moduleId
                        : null,
                    decoration: const InputDecoration(labelText: 'I/O module'),
                    items: _modules.map((module) {
                      final id = module['id'].toString();
                      final name = module['name']?.toString() ?? id;
                      final bus = module['busId'] ?? 0;
                      return DropdownMenuItem(
                        value: id,
                        child: Text('$name • Bus $bus'),
                      );
                    }).toList(),
                    onChanged: _saving
                        ? null
                        : (value) =>
                              value == null ? null : _changeModule(value),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<int>(
                    value: _channels.contains(_channel) ? _channel : null,
                    decoration: InputDecoration(
                      labelText: 'Output channel',
                      hintText: _channels.isEmpty ? 'No free outputs' : null,
                    ),
                    items: _channels
                        .map(
                          (channel) => DropdownMenuItem(
                            value: channel,
                            child: Text('P$channel / Relay ${channel + 1}'),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _channel = value),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _loading || _channel == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────
// 13. QUICK ACTION DIALOG
// ────────────────────────────────────────────────────────────
class _QuickActionDialog extends ConsumerStatefulWidget {
  const _QuickActionDialog();

  @override
  ConsumerState<_QuickActionDialog> createState() => _QuickActionDialogState();
}

class _QuickActionDialogState extends ConsumerState<_QuickActionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  int _type = 0;
  String _room = '';
  String _moduleId = 'io_1';
  int? _channel;
  List<String> _rooms = const [];
  List<Map<String, dynamic>> _types = const [];
  List<Map<String, dynamic>> _modules = const [];
  List<int> _channels = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final results = await Future.wait<dynamic>([
      service.getRooms().catchError((_) => <String>[]),
      service.getDeviceTypes().catchError((_) => <Map<String, dynamic>>[]),
      service.getIoModules().catchError((_) => <Map<String, dynamic>>[]),
    ]);
    final rooms = (results[0] as List).cast<String>();
    var types = (results[1] as List).cast<Map<String, dynamic>>();
    final modules = (results[2] as List).cast<Map<String, dynamic>>();
    if (types.isEmpty) {
      types = [
        {'type': 0, 'name': 'Light'},
        {'type': 1, 'name': 'Fan'},
        {'type': 2, 'name': 'Switch'},
        {'type': 3, 'name': 'Socket'},
      ];
    }
    final moduleId = modules.isEmpty ? 'io_1' : modules.first['id'].toString();
    final channels = await service.getSelectableChannels(moduleId: moduleId);
    if (!mounted) return;
    setState(() {
      _rooms = rooms;
      _room = rooms.isEmpty ? '' : rooms.first;
      _types = types;
      _modules = modules;
      _moduleId = moduleId;
      _channels = channels;
      _channel = channels.isEmpty ? null : channels.first;
      _loading = false;
    });
  }

  Future<void> _selectModule(String moduleId) async {
    setState(() {
      _moduleId = moduleId;
      _loading = true;
    });
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final channels = await service.getSelectableChannels(moduleId: moduleId);
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _channel = channels.isEmpty ? null : channels.first;
      _loading = false;
    });
  }

  Future<void> _manageRooms() async {
    final updated = await showDialog<List<String>>(
      context: context,
      builder: (_) =>
          _RoomManagementDialog(rooms: _rooms, onRoomsUpdated: (_) async {}),
    );
    if (updated == null || !mounted) return;
    setState(() {
      _rooms = updated;
      _room = updated.contains(_room)
          ? _room
          : (updated.isEmpty ? '' : updated.first);
    });
  }

  Future<void> _add() async {
    if (_rooms.isEmpty || _room.isEmpty) {
      _showSnack(context, 'Add a room first.', color: Colors.orange);
      await _manageRooms();
      return;
    }
    if (_channel == null) {
      _showSnack(
        context,
        'This I/O module has no free channels.',
        color: Colors.orange,
      );
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final free = await service.getSelectableChannels(moduleId: _moduleId);
    if (!free.contains(_channel)) {
      if (mounted) {
        setState(() {
          _channels = free;
          _channel = free.isEmpty ? null : free.first;
          _saving = false;
        });
        _showSnack(
          context,
          'That output was just assigned. Choose another.',
          color: Colors.orange,
        );
      }
      return;
    }
    final ok = await service.addDevice(
      name: _nameController.text.trim(),
      type: _type,
      moduleId: _moduleId,
      channel: _channel!,
      room: _room,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.read(dashboardRefreshTickProvider.notifier).state++;
      ref.invalidate(httpDataProvider);
      Navigator.pop(context);
      _showSnack(context, 'Device added.', color: _DT.green);
    } else {
      _showSnack(context, 'Could not add the device.', color: _DT.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.only(bottom: inset),
      child: SafeArea(
        top: false,
        child: _GCard(
          padding: const EdgeInsets.all(22),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Add New Device',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _manageRooms,
                        icon: const Icon(Icons.meeting_room_rounded),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  if (_loading) const LinearProgressIndicator(),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Device name'),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Enter a device name'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<int>(
                    value: _type,
                    decoration: const InputDecoration(labelText: 'Device type'),
                    items: _types
                        .map(
                          (type) => DropdownMenuItem(
                            value: (type['type'] as num).toInt(),
                            child: Text(type['name'].toString()),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _type = value ?? 0),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    value: _modules.any((m) => m['id'].toString() == _moduleId)
                        ? _moduleId
                        : null,
                    decoration: const InputDecoration(labelText: 'I/O module'),
                    items: _modules.map((module) {
                      final id = module['id'].toString();
                      return DropdownMenuItem(
                        value: id,
                        child: Text(
                          '${module['name'] ?? id} • Bus ${module['busId'] ?? 0}',
                        ),
                      );
                    }).toList(),
                    onChanged: _saving || _loading
                        ? null
                        : (value) =>
                              value == null ? null : _selectModule(value),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<int>(
                    value: _channels.contains(_channel) ? _channel : null,
                    decoration: InputDecoration(
                      labelText: 'Module output channel',
                      hintText: _channels.isEmpty ? 'No free outputs' : null,
                    ),
                    items: _channels
                        .map(
                          (c) => DropdownMenuItem(
                            value: c,
                            child: Text('P$c / Relay ${c + 1}'),
                          ),
                        )
                        .toList(),
                    onChanged: _saving || _loading
                        ? null
                        : (value) => setState(() => _channel = value),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    value: _rooms.contains(_room) ? _room : null,
                    decoration: const InputDecoration(labelText: 'Room'),
                    items: _rooms
                        .map(
                          (room) =>
                              DropdownMenuItem(value: room, child: Text(room)),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _room = value ?? ''),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _saving || _loading ? null : _add,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Add Device'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 14. ROOM MANAGEMENT DIALOG
// ────────────────────────────────────────────────────────────
class _RoomManagementDialog extends ConsumerStatefulWidget {
  final List<String> rooms;
  final Function(List<String>) onRoomsUpdated;

  const _RoomManagementDialog({
    required this.rooms,
    required this.onRoomsUpdated,
  });

  @override
  ConsumerState<_RoomManagementDialog> createState() =>
      _RoomManagementDialogState();
}

class _RoomManagementDialogState extends ConsumerState<_RoomManagementDialog> {
  late List<String> _rooms;
  final TextEditingController _newRoomController = TextEditingController();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _rooms = List<String>.from(widget.rooms)
      ..removeWhere((room) => room.trim().isEmpty)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<bool> _persistRooms(List<String> rooms) async {
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final success = await service.saveRooms(rooms);
    if (success) {
      widget.onRoomsUpdated(List<String>.from(rooms));
      ref.read(dashboardRefreshTickProvider.notifier).state++;
    }
    return success;
  }

  Future<void> _addRoom() async {
    final name = _newRoomController.text.trim();
    if (name.isEmpty) return;

    final exists = _rooms.any(
      (room) => room.toLowerCase() == name.toLowerCase(),
    );
    if (exists) {
      _showSnack(context, 'Room already exists', color: Colors.orange);
      return;
    }

    final previous = List<String>.from(_rooms);
    setState(() {
      _rooms.add(name);
      _rooms.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _newRoomController.clear();
      _isSaving = true;
    });

    try {
      final success = await _persistRooms(_rooms);
      if (!mounted) return;
      if (success) {
        _showSnack(context, '✅ Room added: $name', color: _DT.green);
      } else {
        setState(() => _rooms = previous);
        _showSnack(context, '❌ Failed to save room', color: _DT.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rooms = previous);
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _editRoom(String oldRoom) async {
    final controller = TextEditingController(text: oldRoom);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Room'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Room name'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newName == null || newName.isEmpty || newName == oldRoom) return;
    final exists = _rooms.any(
      (room) => room != oldRoom && room.toLowerCase() == newName.toLowerCase(),
    );
    if (exists) {
      _showSnack(context, 'Room already exists', color: Colors.orange);
      return;
    }

    final previous = List<String>.from(_rooms);
    setState(() {
      final index = _rooms.indexOf(oldRoom);
      if (index != -1) _rooms[index] = newName;
      _rooms.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _isSaving = true;
    });

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final roomsSaved = await service.saveRooms(_rooms);
      final devicesRenamed = await service.renameRoomInDevices(
        oldRoom: oldRoom,
        newRoom: newName,
      );
      if (!mounted) return;

      if (roomsSaved && devicesRenamed) {
        await ref.read(roomImageStoreProvider).rename(oldRoom, newName);
        ref.invalidate(roomImageProvider(oldRoom));
        ref.invalidate(roomImageProvider(newName));
        widget.onRoomsUpdated(List<String>.from(_rooms));
        ref.read(dashboardRefreshTickProvider.notifier).state++;
        _showSnack(context, '✅ Room renamed', color: _DT.green);
      } else {
        setState(() => _rooms = previous);
        await service.saveRooms(previous);
        _showSnack(context, '❌ Failed to rename room', color: _DT.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rooms = previous);
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removeRoom(String room) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Room'),
        content: Text(
          'Delete "$room" from the room list? Devices already assigned to this room will stay in Firebase, but the room tab will disappear until you add/rename it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _DT.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final previous = List<String>.from(_rooms);
    setState(() {
      _rooms.remove(room);
      _isSaving = true;
    });

    try {
      final success = await _persistRooms(_rooms);
      if (!mounted) return;
      if (success) {
        await ref.read(roomImageStoreProvider).remove(room);
        ref.invalidate(roomImageProvider(room));
        _showSnack(context, '🗑️ Room removed: $room', color: _DT.amber);
      } else {
        setState(() => _rooms = previous);
        _showSnack(context, '❌ Failed to remove room', color: _DT.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rooms = previous);
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _newRoomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.transparent,
        child: _GCard(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Manage Rooms',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  _rooms.isEmpty
                      ? 'No rooms yet'
                      : '${_rooms.length} rooms total',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _newRoomController,
                        decoration: InputDecoration(
                          hintText: 'New room name',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        onFieldSubmitted: (_) => _addRoom(),
                        enabled: !_isSaving,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _isSaving ? null : _addRoom,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: _rooms.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Column(
                            children: [
                              Icon(
                                Icons.meeting_room_outlined,
                                size: 42,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.25),
                              ),
                              const SizedBox(height: 10),
                              const Text('No rooms yet. Add your first room!'),
                            ],
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: _rooms.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final room = _rooms[index];
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.05),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.room_rounded,
                                    color: _DT.purple,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(room)),
                                  IconButton(
                                    tooltip: 'Edit room',
                                    icon: const Icon(
                                      Icons.edit_rounded,
                                      color: _DT.purple,
                                      size: 20,
                                    ),
                                    onPressed: _isSaving
                                        ? null
                                        : () => _editRoom(room),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete room',
                                    icon: const Icon(
                                      Icons.delete_rounded,
                                      color: _DT.red,
                                      size: 20,
                                    ),
                                    onPressed: _isSaving
                                        ? null
                                        : () => _removeRoom(room),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSaving
                        ? null
                        : () =>
                              Navigator.pop(context, List<String>.from(_rooms)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _DT.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 15. PURPLE FAB
// ────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────
// 16. GLASS APP BAR
// ────────────────────────────────────────────────────────────

class _ABBtn extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _ABBtn({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: onTap, child: child);
}

class _DesktopSidebar extends StatelessWidget {
  final int selectedIndex;
  final String assistantName;
  final ValueChanged<int> onTap;
  final VoidCallback onAdd;
  final VoidCallback onAssistant;

  const _DesktopSidebar({
    required this.selectedIndex,
    required this.assistantName,
    required this.onTap,
    required this.onAdd,
    required this.onAssistant,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const items = <(IconData, String)>[
      (Icons.grid_view_rounded, 'Dashboard'),
      (Icons.bolt_rounded, 'Energy'),
      (Icons.notifications_rounded, 'Alerts'),
      (Icons.settings_rounded, 'Settings'),
    ];

    return Container(
      width: 226,
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF050914).withValues(alpha: 0.78)
            : Colors.white.withValues(alpha: 0.70),
        border: Border(
          right: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, kToolbarHeight + 18, 16, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: const LinearGradient(
                        colors: [_DT.blue, _DT.purple],
                      ),
                    ),
                    child: const Icon(
                      Icons.home_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 11),
                  const Text(
                    'SmartHome',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 34),
              for (var index = 0; index < items.length; index++) ...[
                _DesktopNavItem(
                  icon: items[index].$1,
                  label: items[index].$2,
                  selected: selectedIndex == index,
                  onTap: () => onTap(index),
                ),
                const SizedBox(height: 8),
              ],
              const Spacer(),
              Material(
                color: _DT.purple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  onTap: onAssistant,
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        const Icon(Icons.graphic_eq_rounded, color: _DT.purple),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                assistantName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const Text(
                                'Voice assistant',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('Add room or device'),
                style: FilledButton.styleFrom(
                  backgroundColor: _DT.purple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DesktopNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? _DT.purple.withValues(alpha: 0.18) : Colors.transparent,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? _DT.purple.withValues(alpha: 0.28)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: selected ? _DT.purple : Colors.grey),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: selected ? null : Colors.grey,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ────────────────────────────────────────────────────────────
// 17. HOME CONTENT WRAPPER
// ────────────────────────────────────────────────────────────
class _HomeContentWrapper extends ConsumerStatefulWidget {
  const _HomeContentWrapper();

  @override
  ConsumerState<_HomeContentWrapper> createState() =>
      _HomeContentWrapperState();
}

class _HomeContentWrapperState extends ConsumerState<_HomeContentWrapper> {
  Future<void> _refresh() async {
    final ble = ref.read(bleServiceProvider);
    if (ble.isConnected) {
      await ble.refreshDevices().catchError((_) {});
    }
    ref.invalidate(httpDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(smartHomeDataProvider);
    final bleService = ref.watch(bleServiceProvider);
    final refreshTick = ref.watch(dashboardRefreshTickProvider);
    return _HomeContent(
      key: ValueKey(refreshTick),
      dataAsync: dataAsync,
      onRefresh: _refresh,
      bleStatus: bleService.currentStatus,
      onConnectBLE: () => unawaited(bleService.connect().catchError((_) {})),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 18. HOME CONTENT - DYNAMIC DEVICES FROM ESP32
// ────────────────────────────────────────────────────────────
class _HomeContent extends ConsumerStatefulWidget {
  final AsyncValue<Map<String, dynamic>> dataAsync;
  final Future<void> Function() onRefresh;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;

  const _HomeContent({
    super.key,
    required this.dataAsync,
    required this.onRefresh,
    required this.bleStatus,
    required this.onConnectBLE,
  });

  @override
  ConsumerState<_HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends ConsumerState<_HomeContent>
    with WidgetsBindingObserver {
  bool _dashboardRefreshInProgress = false;
  int _deviceRevision = 0;
  String _selectedRoom = '';
  List<String> _rooms = [];
  Map<String, dynamic> _esp32Devices = {'devices': []};
  bool _isLoadingDevices = false;
  bool _initialLoadDone = false;
  Timer? _refreshTimer;
  final Map<String, bool> _pendingDeviceStates = {};
  final Map<String, DateTime> _pendingDeviceStateTimes = {};
  final Set<String> _togglingDeviceIds = {};
  bool? _lastFlameDetected;
  bool? _lastEspOnline;
  bool? _lastBleConnected;

  static const Duration _pendingStateHold = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDashboardState();

    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted) _loadDashboardStateSilently();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _refreshTimer?.cancel();
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadDashboardStateSilently());
      _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
        if (mounted) unawaited(_loadDashboardStateSilently());
      });
    }
  }

  void updateDevices(Map<String, dynamic> newDevices) {
    setState(() {
      _esp32Devices = newDevices;
    });
  }

  List<String> _getVisibleRooms(List<dynamic> devicesList) {
    final Set<String> roomSet = {..._rooms};

    // Migration fallback only. If the user already has devices from the old
    // database but /rooms is empty, show their device rooms. No fake defaults.
    if (roomSet.isEmpty) {
      for (final device in devicesList) {
        if (device is Map && device['room'] != null) {
          final room = device['room'].toString().trim();
          if (room.isNotEmpty) roomSet.add(room);
        }
      }
    }

    return roomSet.toList()..sort((a, b) {
      int order(String s) {
        final n = s.toLowerCase();
        if (RegExp(r'living|معيشة|صالون').hasMatch(n)) return 0;
        if (RegExp(r'bed|نوم').hasMatch(n)) return 1;
        if (RegExp(r'kitchen|مطبخ').hasMatch(n)) return 2;
        if (RegExp(r'bath|حمام').hasMatch(n)) return 3;
        return 4;
      }

      final cmp = order(a).compareTo(order(b));
      return cmp == 0 ? a.toLowerCase().compareTo(b.toLowerCase()) : cmp;
    });
  }

  String _effectiveSelectedRoom(List<String> rooms) {
    if (rooms.isEmpty) return '';
    if (rooms.contains(_selectedRoom)) return _selectedRoom;
    return rooms.firstWhere(
      (r) => RegExp(r'living|معيشة|صالون').hasMatch(r.toLowerCase()),
      orElse: () => rooms.first,
    );
  }

  void _syncSelectedRoom(List<String> rooms) {
    final effective = _effectiveSelectedRoom(rooms);
    if (_selectedRoom != effective) {
      _selectedRoom = effective;
    }
  }

  List<Map<String, dynamic>> _applyPendingDeviceStates(
    List<dynamic> rawDevices,
  ) {
    final now = DateTime.now();
    final expired = <String>[];

    final devices = rawDevices.whereType<Map>().map((device) {
      final updated = Map<String, dynamic>.from(device);
      final id = updated['id']?.toString() ?? '';
      if (id.isEmpty) return updated;

      final pendingState = _pendingDeviceStates[id];
      final pendingAt = _pendingDeviceStateTimes[id];
      if (pendingState == null || pendingAt == null) return updated;

      final fetchedState = updated['state'] as bool?;
      if (fetchedState == pendingState) {
        expired.add(id);
        return updated;
      }

      if (now.difference(pendingAt) <= _pendingStateHold) {
        updated['state'] = pendingState;
      } else {
        expired.add(id);
      }
      return updated;
    }).toList();

    for (final id in expired) {
      _pendingDeviceStates.remove(id);
      _pendingDeviceStateTimes.remove(id);
      _togglingDeviceIds.remove(id);
    }

    return devices;
  }

  bool _deviceListsEqual(List<dynamic> a, List<dynamic> b) {
    return jsonEncode(a) == jsonEncode(b);
  }

  void _syncSystemNotifications({
    required bool flame,
    required bool online,
    required BleStatus bleStatus,
  }) {
    final controller = ref.read(appNotificationsProvider.notifier);
    final bleConnected =
        bleStatus == BleStatus.connected || bleStatus == BleStatus.dataUpdated;

    if (_lastFlameDetected != null && _lastFlameDetected != flame) {
      if (flame) {
        controller.push(
          key: 'flame_alert',
          title: 'Flame detected',
          message:
              'The flame sensor reported a possible fire event. Check the area now.',
          icon: Icons.local_fire_department_rounded,
          color: _DT.red,
          suppressFor: const Duration(seconds: 10),
        );
      } else {
        controller.push(
          key: 'flame_clear',
          title: 'Flame sensor clear',
          message: 'The flame sensor returned to a safe state.',
          icon: Icons.shield_rounded,
          color: _DT.green,
        );
      }
    }

    if (_lastEspOnline != null && _lastEspOnline != online) {
      controller.push(
        key: online ? 'esp_online' : 'esp_offline',
        title: online ? 'ESP32 is online' : 'ESP32 is offline',
        message: online
            ? 'Wi-Fi/Firebase control is available again.'
            : 'Remote control is unavailable. Bluetooth backup can still control nearby devices.',
        icon: online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
        color: online ? _DT.green : _DT.red,
      );
    }

    if (_lastBleConnected != null && _lastBleConnected != bleConnected) {
      controller.push(
        key: bleConnected ? 'ble_connected' : 'ble_disconnected',
        title: bleConnected
            ? 'Bluetooth backup connected'
            : 'Bluetooth backup disconnected',
        message: bleConnected
            ? 'Direct offline control is ready.'
            : 'Bluetooth backup is not connected.',
        icon: bleConnected
            ? Icons.bluetooth_connected_rounded
            : Icons.bluetooth_disabled_rounded,
        color: bleConnected ? _DT.blue : Colors.grey,
      );
    }

    _lastFlameDetected = flame;
    _lastEspOnline = online;
    _lastBleConnected = bleConnected;
  }

  Future<void> _loadDashboardState() async {
    if (_dashboardRefreshInProgress || !mounted) return;
    _dashboardRefreshInProgress = true;
    setState(() => _isLoadingDevices = true);

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final result = await service.getDevices();
      final rooms = await service.getRooms();
      final devicesList = _applyPendingDeviceStates(
        result['devices'] as List? ?? [],
      );
      final visibleRooms = {...rooms};
      if (visibleRooms.isEmpty) {
        for (final device in devicesList) {
          if (device is Map && device['room'] != null) {
            final room = device['room'].toString().trim();
            if (room.isNotEmpty) visibleRooms.add(room);
          }
        }
      }
      final sortedRooms = visibleRooms.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _esp32Devices = {'devices': devicesList};
        _rooms = sortedRooms;
        _syncSelectedRoom(_rooms);
        _isLoadingDevices = false;
        _initialLoadDone = true;
      });
    } catch (e) {
      logDebug('Error loading ESP32 dashboard state: $e');
      if (!mounted) return;

      // Keep the last known dashboard state when cloud/http is unavailable.
      // If BLE is connected, use its device cache instead of clearing rooms.
      final ble = ref.read(bleServiceProvider);
      List<Map<String, dynamic>> bleDevices = const [];
      if (ble.isConnected) {
        try {
          await ble.refreshDevices().timeout(const Duration(seconds: 4));
          bleDevices = ble.devices
              .map((d) => Map<String, dynamic>.from(d))
              .toList();
        } catch (_) {
          bleDevices = ble.devices
              .map((d) => Map<String, dynamic>.from(d))
              .toList();
        }
      }

      if (!mounted) return;
      setState(() {
        if (bleDevices.isNotEmpty) {
          final visibleRooms = <String>{};
          for (final device in bleDevices) {
            final room = device['room']?.toString().trim() ?? '';
            if (room.isNotEmpty) visibleRooms.add(room);
          }
          _esp32Devices = {'devices': bleDevices};
          _rooms = visibleRooms.toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          _syncSelectedRoom(_rooms);
        }
        _isLoadingDevices = false;
        _initialLoadDone = true;
      });
    } finally {
      _dashboardRefreshInProgress = false;
    }
  }

  Future<void> _loadDashboardStateSilently() async {
    if (_dashboardRefreshInProgress || !mounted) return;
    _dashboardRefreshInProgress = true;
    final revision = _deviceRevision;
    try {
      if (_togglingDeviceIds.isNotEmpty) {
        return;
      }

      final service = await ref.read(esp32DeviceServiceProvider.future);
      final result = await service.getDevices();
      final rooms = await service.getRooms();
      if (!mounted || revision != _deviceRevision) return;
      final mergedDevices = _applyPendingDeviceStates(
        result['devices'] as List? ?? [],
      );
      final currentDevices = _esp32Devices['devices'] as List? ?? [];
      final nextRooms = rooms.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      // Never let a temporary empty Firebase/local HTTP response wipe the
      // already visible dashboard. This was the reason rooms/devices could
      // disappear after moving between tabs.
      if (mergedDevices.isEmpty && currentDevices.isNotEmpty) return;
      if (nextRooms.isEmpty && _rooms.isNotEmpty && mergedDevices.isEmpty)
        return;

      final roomsChanged = jsonEncode(_rooms) != jsonEncode(nextRooms);
      final devicesChanged = !_deviceListsEqual(currentDevices, mergedDevices);
      if (!roomsChanged && !devicesChanged) return;

      setState(() {
        _esp32Devices = {'devices': mergedDevices};
        _rooms = nextRooms.isEmpty
            ? _getVisibleRooms(mergedDevices)
            : nextRooms;
        _syncSelectedRoom(_getVisibleRooms(mergedDevices));
      });
    } catch (_) {
      // Silent fail for auto-refresh.
    } finally {
      _dashboardRefreshInProgress = false;
    }
  }

  Future<void> _refreshDevices() async {
    await _loadDashboardState();
    await widget.onRefresh();
  }

  void _showDeviceOptions(
    String deviceId,
    String deviceName,
    String currentModuleId,
    int currentChannel,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _GCard(
        padding: const EdgeInsets.all(20),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _DT.purple.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.devices_rounded,
                color: _DT.purple,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              deviceName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              currentChannel >= 0
                  ? 'Current output: $currentModuleId/P$currentChannel / Relay ${currentChannel + 1}'
                  : 'Output not assigned — choose P0 to P7',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            _OptionTile(
              icon: Icons.edit_rounded,
              title: 'Assign PCF8574 Output',
              subtitle: 'Choose an I/O module and output P0 to P7',
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (context) => _EditChannelDialog(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    currentModuleId: currentModuleId,
                    currentChannel: currentChannel,
                  ),
                ).then((refreshed) {
                  if (refreshed == true) _loadDashboardState();
                });
              },
            ),
            const Divider(height: 1),
            _OptionTile(
              icon: Icons.delete_rounded,
              title: 'Remove Device',
              subtitle: 'Delete this device',
              onTap: () {
                Navigator.pop(context);
                _showRemoveDeviceDialog(deviceId, deviceName);
              },
              iconColor: _DT.red,
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _showRemoveDeviceDialog(String deviceId, String deviceName) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.transparent,
        child: _GCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _DT.red.withValues(alpha: 0.15),
                ),
                child: const Icon(
                  Icons.warning_rounded,
                  color: _DT.red,
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Remove Device',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Are you sure you want to remove "$deviceName"?',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        try {
                          final service = await ref.read(
                            esp32DeviceServiceProvider.future,
                          );
                          final success = await service.removeDevice(deviceId);
                          if (success) {
                            await _loadDashboardState();
                            _showSnack(
                              context,
                              '✅ Device removed',
                              color: _DT.green,
                            );
                          } else {
                            _showSnack(
                              context,
                              '❌ Failed to remove device',
                              color: _DT.red,
                            );
                          }
                        } catch (e) {
                          _showSnack(
                            context,
                            '❌ Error: ${e.toString()}',
                            color: _DT.red,
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.red,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Remove'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _controlDevice(String id, bool state) async {
    if (_togglingDeviceIds.contains(id)) return;
    _deviceRevision++;

    final devices = List<dynamic>.from(_esp32Devices['devices'] as List? ?? []);
    final index = devices.indexWhere((d) => d is Map && d['id'] == id);
    final previousState = index != -1 && devices[index] is Map
        ? ((devices[index] as Map)['state'] as bool? ?? false)
        : !state;

    _pendingDeviceStates[id] = state;
    _pendingDeviceStateTimes[id] = DateTime.now();
    _togglingDeviceIds.add(id);

    if (index != -1 && devices[index] is Map) {
      final updatedDevice = Map<String, dynamic>.from(devices[index] as Map);
      updatedDevice['state'] = state;
      devices[index] = updatedDevice;
      setState(() => _esp32Devices = {'devices': devices});
    }

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final success = await service.controlDevice(id: id, state: state);

      if (!mounted) return;

      if (!success) {
        _pendingDeviceStates.remove(id);
        _pendingDeviceStateTimes.remove(id);
        _togglingDeviceIds.remove(id);

        final revertedDevices = List<dynamic>.from(
          _esp32Devices['devices'] as List? ?? [],
        );
        final revertIndex = revertedDevices.indexWhere(
          (d) => d is Map && d['id'] == id,
        );
        if (revertIndex != -1 && revertedDevices[revertIndex] is Map) {
          final revertedDevice = Map<String, dynamic>.from(
            revertedDevices[revertIndex] as Map,
          );
          revertedDevice['state'] = previousState;
          revertedDevices[revertIndex] = revertedDevice;
          setState(() => _esp32Devices = {'devices': revertedDevices});
        }
        _showSnack(context, '❌ Failed to control device', color: _DT.red);
        return;
      }

      final deviceName = index != -1 && devices[index] is Map
          ? ((devices[index] as Map)['name']?.toString() ?? 'Device')
          : 'Device';
      ref
          .read(appNotificationsProvider.notifier)
          .push(
            key: 'device_${id}_state',
            title: '$deviceName ${state ? 'turned on' : 'turned off'}',
            message:
                'PCF8574 channel command was accepted by the active control path.',
            icon: state ? Icons.power_rounded : Icons.power_off_rounded,
            color: state ? _DT.green : Colors.grey,
            suppressFor: const Duration(seconds: 2),
          );

      // Unlock the button after the command completes, but keep the optimistic
      // state until a fresh ESP32 read confirms it. Removing the pending state
      // after only 350 ms allowed an older BLE/Firebase value to flash back ON.
      setState(() => _togglingDeviceIds.remove(id));
      Future.delayed(const Duration(milliseconds: 180), () {
        if (!mounted) return;
        unawaited(_loadDashboardStateSilently());
      });
    } catch (e) {
      if (!mounted) return;
      _pendingDeviceStates.remove(id);
      _pendingDeviceStateTimes.remove(id);
      _togglingDeviceIds.remove(id);

      final revertedDevices = List<dynamic>.from(
        _esp32Devices['devices'] as List? ?? [],
      );
      final revertIndex = revertedDevices.indexWhere(
        (d) => d is Map && d['id'] == id,
      );
      if (revertIndex != -1 && revertedDevices[revertIndex] is Map) {
        final revertedDevice = Map<String, dynamic>.from(
          revertedDevices[revertIndex] as Map,
        );
        revertedDevice['state'] = previousState;
        revertedDevices[revertIndex] = revertedDevice;
        setState(() => _esp32Devices = {'devices': revertedDevices});
      }
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    }
  }

  Future<void> _setRoomDevices(List<dynamic> devices, bool state) async {
    final targets = devices
        .whereType<Map>()
        .where((device) {
          final id = device['id']?.toString() ?? '';
          final currentState = device['state'] as bool? ?? false;
          return id.isNotEmpty && currentState != state;
        })
        .toList(growable: false);

    for (final device in targets) {
      await _controlDevice(device['id'].toString(), state);
    }
  }

  @override
  Widget build(BuildContext context) {
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    if (!_initialLoadDone) {
      return const _SkeletonLoader();
    }

    return RefreshIndicator(
      onRefresh: _refreshDevices,
      displacement: 100,
      color: _DT.purple,
      child: widget.dataAsync.when(
        data: (data) {
          final sensors = (data['sensors'] as Map?) ?? {};
          final temp = (sensors['temperature'] as num?)?.toDouble();
          final hum = (sensors['humidity'] as num?)?.toDouble();
          final flame = sensors['flame'] == true;
          final status = (data['status'] as Map?) ?? {};
          final online = status['online'] ?? false;
          final ip = status['ip']?.toString();
          final ping = (status['ping'] as num?)?.toInt();
          final rssi = (status['rssi'] as num?)?.toInt();
          final energy = (data['energy'] as Map?) ?? {};
          final todayKw = (energy['today'] as num?)?.toDouble();

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _syncSystemNotifications(
              flame: flame,
              online: online == true,
              bleStatus: widget.bleStatus,
            );
          });

          final devicesList = _esp32Devices['devices'] as List? ?? [];
          final rooms = _getVisibleRooms(devicesList);
          final selectedRoom = _effectiveSelectedRoom(rooms);
          final roomDevices = selectedRoom.isEmpty
              ? <dynamic>[]
              : devicesList
                    .where((d) => d is Map && d['room'] == selectedRoom)
                    .toList();

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: 12,
              left: isDesktop ? padding : 14,
              right: isDesktop ? padding : 14,
              bottom: 8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HomeHero(
                  title: 'Good Evening',
                  height: 140,
                  compact: true,
                  subtitle: 'Your home feels just right.',
                  trailing: IconButton.filledTonal(
                    tooltip: 'Settings',
                    onPressed: () =>
                        ref.read(selectedNavIndexProvider.notifier).state = 3,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ),
                const SizedBox(height: 6),
                HomeScenes(
                  scope:
                      ref
                          .read(authServiceProvider)
                          .asData
                          ?.value
                          .currentUser
                          ?.uid ??
                      'local',
                  devices: devicesList,
                  onToggle: _controlDevice,
                ),
                const SizedBox(height: 6),
                _EspBar(
                  online: online,
                  ip: ip,
                  ping: ping,
                  rssi: rssi,
                  bleStatus: widget.bleStatus,
                  onConnectBLE: widget.onConnectBLE,
                ),
                const SizedBox(height: 6),
                _StatsRow(temp: temp, hum: hum, todayKw: todayKw),
                if (flame) ...[
                  const SizedBox(height: 8),
                  _FlameBanner(flame: flame),
                ],
                const SizedBox(height: 9),
                _RoomGallery(
                  selectedRoom: selectedRoom,
                  onRoomSelected: (r) => setState(() => _selectedRoom = r),
                  rooms: rooms,
                  devices: devicesList,
                ),
                const SizedBox(height: 8),
                if (_isLoadingDevices)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: const LinearProgressIndicator(
                      color: _DT.purple,
                      backgroundColor: Colors.transparent,
                      minHeight: 2,
                    ),
                  )
                else if (rooms.isEmpty)
                  _GCard(
                    padding: const EdgeInsets.all(30),
                    child: Column(
                      children: [
                        Icon(
                          Icons.meeting_room_outlined,
                          size: 48,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No rooms yet',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Use the Room button above to create your first room.',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                else
                  _FocusedRoomPanel(
                    room: selectedRoom,
                    devices: roomDevices,
                    onToggle: _controlDevice,
                    onOptions: _showDeviceOptions,
                    onSetAll: (state) => _setRoomDevices(roomDevices, state),
                    pendingIds: _togglingDeviceIds,
                  ),
              ],
            ),
          );
        },
        loading: () => const _SkeletonLoader(),
        error: (err, _) => Center(
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: _GCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 48,
                    color: _DT.red,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Something went wrong',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    err.toString(),
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  _PillBtn(label: 'Try Again', onTap: _refreshDevices),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 19. DYNAMIC DEVICE CARD
// ────────────────────────────────────────────────────────────
class _EspBar extends StatelessWidget {
  const _EspBar({
    required this.online,
    required this.ip,
    required this.ping,
    required this.rssi,
    required this.bleStatus,
    required this.onConnectBLE,
  });
  final bool online;
  final String? ip;
  final int? ping, rssi;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;
  @override
  Widget build(BuildContext context) {
    final connected =
        bleStatus == BleStatus.connected || bleStatus == BleStatus.dataUpdated;
    final busy =
        bleStatus == BleStatus.scanning || bleStatus == BleStatus.connecting;
    return HomeCard(
      padding: const EdgeInsets.all(9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const HomeGlowIcon(
                Icons.wifi,
                color: Color(0xFF21E4D3),
                size: 32,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      online ? 'System Connected' : 'System Offline',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Wi-Fi / Firebase with BLE backup',
                      style: TextStyle(fontSize: 9, color: Color(0xFFA7B9D7)),
                    ),
                  ],
                ),
              ),
              IconButton(
                constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                padding: EdgeInsets.zero,
                tooltip: connected ? 'BLE connected' : 'Connect BLE',
                onPressed: connected || busy ? null : onConnectBLE,
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final t in [
                online ? '● ESP online' : '● ESP offline',
                connected ? '● BLE connected' : 'BLE offline',
                ip ?? 'IP —',
                rssi == null ? '— dBm' : '$rssi dBm',
                ping == null ? '— ms' : '$ping ms',
              ])
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141E2F),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: HomeDesign.border),
                  ),
                  child: Text(
                    t,
                    style: const TextStyle(
                      fontSize: 8,
                      color: Color(0xFFDCE5F7),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 21. STATS ROW
// ────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  final double? temp;
  final double? hum;
  final double? todayKw;

  const _StatsRow({
    required this.temp,
    required this.hum,
    required this.todayKw,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.thermostat_rounded,
            iconColor: const Color(0xFFFF6B6B),
            value: temp == null ? '—' : '${temp!.toStringAsFixed(1)}°',
            label: 'Temperature',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatTile(
            icon: Icons.water_drop_rounded,
            iconColor: _DT.blue,
            value: hum == null ? '—' : '${hum!.toStringAsFixed(0)}%',
            label: 'Humidity',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatTile(
            icon: Icons.bolt_rounded,
            iconColor: _DT.amber,
            value: todayKw == null ? '—' : '${todayKw!.toStringAsFixed(1)} kWh',
            label: 'Today’s Energy',
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final Color iconColor;
  final String value, label;
  @override
  Widget build(BuildContext context) {
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 8,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ],
    );
    return HomeCard(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 7),
      child: MediaQuery.textScalerOf(context).scale(1) > 1.3
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: iconColor, size: 20),
                const SizedBox(height: 6),
                text,
              ],
            )
          : Row(
              children: [
                Icon(icon, color: iconColor, size: 19),
                const SizedBox(width: 7),
                Expanded(child: text),
              ],
            ),
    );
  }
}

class _FlameBanner extends StatelessWidget {
  final bool flame;
  const _FlameBanner({required this.flame});

  @override
  Widget build(BuildContext context) {
    final color = flame ? _DT.red : _DT.green;
    return _GCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      glowColor: color,
      dangerBorder: flame,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: color.withValues(alpha: 0.15),
            ),
            child: Icon(
              flame
                  ? Icons.local_fire_department_rounded
                  : Icons.shield_rounded,
              color: color,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  flame ? '⚠️ FLAME DETECTED' : 'All Clear',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  flame
                      ? 'Immediate action required'
                      : 'Flame Sensor • No alerts detected',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 23. ROOMS HEADER + TABS (UPDATED WITH DYNAMIC ROOMS)
// ────────────────────────────────────────────────────────────
const String _roomArtAsset = 'assets/images/smart_room_ambient.png';

IconData _roomIconFor(String roomName) {
  final name = roomName.toLowerCase();
  if (name.contains('living') || name.contains('lounge')) {
    return Icons.weekend_rounded;
  }
  if (name.contains('bed') || name.contains('guest')) {
    return Icons.bed_rounded;
  }
  if (name.contains('kitchen') || name.contains('dining')) {
    return Icons.soup_kitchen_rounded;
  }
  if (name.contains('bath')) return Icons.bathtub_rounded;
  if (name.contains('office') || name.contains('study')) {
    return Icons.desktop_windows_rounded;
  }
  if (name.contains('garage')) return Icons.garage_rounded;
  if (name.contains('garden') || name.contains('yard')) {
    return Icons.yard_rounded;
  }
  return Icons.meeting_room_rounded;
}

Color _roomAccentFor(String roomName) {
  const accents = <Color>[
    Color(0xFF8B5CFF),
    Color(0xFF4E8CFF),
    Color(0xFFFF8F6B),
    Color(0xFF4FD4B1),
    Color(0xFFE26FAE),
  ];
  final hash = roomName.codeUnits.fold<int>(0, (sum, value) => sum + value);
  return accents[hash % accents.length];
}

Alignment _roomArtAlignment(String roomName) {
  const alignments = <Alignment>[
    Alignment.centerLeft,
    Alignment.center,
    Alignment.centerRight,
    Alignment(-0.45, 0),
    Alignment(0.45, 0),
  ];
  final hash = roomName.codeUnits.fold<int>(0, (sum, value) => sum + value);
  return alignments[hash % alignments.length];
}

class _RoomGallery extends ConsumerWidget {
  final String selectedRoom;
  final ValueChanged<String> onRoomSelected;
  final List<String> rooms;
  final List<dynamic> devices;

  const _RoomGallery({
    required this.selectedRoom,
    required this.onRoomSelected,
    required this.rooms,
    required this.devices,
  });

  Future<void> _manageRooms(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _RoomManagementDialog(rooms: rooms, onRoomsUpdated: (_) {}),
    );
  }

  Future<void> _addDevice(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (context) => const _QuickActionDialog(),
    );
  }

  Future<void> _changeRoomPhoto(
    BuildContext context,
    WidgetRef ref,
    String room,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _GCard(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Change $room photo',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: const Text('Choose from photos'),
                onTap: () => Navigator.pop(context, 'gallery'),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt_rounded),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
              ListTile(
                leading: const Icon(Icons.restore_rounded),
                title: const Text('Use default photo'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null) return;

    final store = ref.read(roomImageStoreProvider);
    if (action == 'remove') {
      await store.remove(room);
      ref.invalidate(roomImageProvider(room));
      return;
    }

    final source = action == 'camera'
        ? ImageSource.camera
        : ImageSource.gallery;
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1200,
        imageQuality: 84,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.lengthInBytes > 2500000) {
        if (context.mounted) {
          _showSnack(
            context,
            'Choose a photo smaller than 2.5 MB',
            color: _DT.amber,
          );
        }
        return;
      }
      await store.save(room, bytes);
      ref.invalidate(roomImageProvider(room));
      if (context.mounted) {
        _showSnack(context, 'Room photo updated', color: _DT.green);
      }
    } catch (_) {
      if (context.mounted) {
        _showSnack(context, 'Could not open that photo', color: _DT.red);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
            final heading = const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Rooms',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                SizedBox(height: 3),
                Text(
                  'Choose a room to see only its controls',
                  style: TextStyle(fontSize: 9, color: Color(0xFFA8B9D4)),
                ),
              ],
            );
            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: 'Add or manage rooms',
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_manageRooms(context)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 9,
                      ),
                      textStyle: const TextStyle(fontSize: 8),
                    ),
                    icon: const Icon(Icons.grid_view, size: 12),
                    label: const Text('Manage Rooms'),
                  ),
                ),
                const SizedBox(width: 5),
                Tooltip(
                  message: 'Add device',
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_addDevice(context)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 9,
                      ),
                      textStyle: const TextStyle(fontSize: 8),
                    ),
                    icon: const Icon(Icons.add, size: 12),
                    label: const Text('Add Device'),
                  ),
                ),
              ],
            );
            if (largeText || constraints.maxWidth < 380) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [heading, const SizedBox(height: 8), actions],
              );
            }
            return Row(
              children: [
                Expanded(child: heading),
                const SizedBox(width: 8),
                actions,
              ],
            );
          },
        ),
        if (rooms.isNotEmpty) ...[
          const SizedBox(height: 9),
          LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(
                context,
              ).scale(1).clamp(1.0, 2.0);
              final columns = constraints.maxWidth < 280 || scale > 1.3
                  ? 1
                  : constraints.maxWidth >= 900
                  ? 4
                  : constraints.maxWidth >= 650
                  ? 3
                  : 2;
              final cardWidth =
                  (constraints.maxWidth - 9 * (columns - 1)) / columns;
              return Wrap(
                spacing: 9,
                runSpacing: 9,
                children: [
                  for (final room in rooms)
                    SizedBox(
                      width: cardWidth,
                      height: 97 + (scale - 1) * 64,
                      child: RoomPhotoCard(
                        room: room,
                        deviceCount: devices
                            .where((d) => d is Map && d['room'] == room)
                            .length,
                        activeCount: devices
                            .where(
                              (d) =>
                                  d is Map &&
                                  d['room'] == room &&
                                  d['state'] == true,
                            )
                            .length,
                        selected: room == selectedRoom,
                        imageBytes: ref
                            .watch(roomImageProvider(room))
                            .asData
                            ?.value,
                        imageAlignment: _roomArtAlignment(room),
                        icon: _roomIconFor(room),
                        onChangeImage: () =>
                            unawaited(_changeRoomPhoto(context, ref, room)),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onRoomSelected(room);
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

class _FocusedRoomPanel extends ConsumerWidget {
  final String room;
  final Set<String> pendingIds;
  final List<dynamic> devices;
  final Future<void> Function(String id, bool state) onToggle;
  final void Function(String id, String name, String moduleId, int channel)
  onOptions;
  final Future<void> Function(bool state) onSetAll;

  const _FocusedRoomPanel({
    required this.room,
    required this.pendingIds,
    required this.devices,
    required this.onToggle,
    required this.onOptions,
    required this.onSetAll,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) => HomeCard(
    padding: const EdgeInsets.all(8),
    child: Column(
      children: [
        Row(
          children: [
            HomeGlowIcon(_roomIconFor(room), size: 28),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$room controls',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '${devices.where((d) => d is Map && d['state'] == true).length} devices active',
                    style: const TextStyle(
                      fontSize: 9,
                      color: Color(0xFF9EAFCC),
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<bool>(
              tooltip: 'Room actions',
              onSelected: (v) => unawaited(onSetAll(v)),
              itemBuilder: (_) => const [
                PopupMenuItem(value: true, child: Text('All on')),
                PopupMenuItem(value: false, child: Text('All off')),
              ],
              child: const Padding(
                padding: EdgeInsets.all(7),
                child: Text(
                  'View All ›',
                  style: TextStyle(fontSize: 9, color: Color(0xFFA3B4D4)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (devices.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No devices in this room yet'),
          )
        else
          LayoutBuilder(
            builder: (context, c) {
              final count = MediaQuery.textScalerOf(context).scale(1) > 1.3
                  ? 2
                  : 4;
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final d in devices.whereType<Map>())
                    SizedBox(
                      width: (c.maxWidth - 6 * (count - 1)) / count,
                      child: _RoomDeviceRow(
                        device: Map<String, dynamic>.from(d),
                        pending: pendingIds.contains(d['id']?.toString()),
                        onToggle: onToggle,
                        onOptions: onOptions,
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    ),
  );
}

class _RoomDeviceRow extends StatelessWidget {
  final Map<String, dynamic> device;
  final bool pending;
  final Future<void> Function(String id, bool state) onToggle;
  final void Function(String id, String name, String moduleId, int channel)
  onOptions;

  const _RoomDeviceRow({
    required this.device,
    this.pending = false,
    required this.onToggle,
    required this.onOptions,
  });

  IconData _iconFor(int type) {
    switch (type) {
      case 0:
        return Icons.lightbulb_rounded;
      case 1:
        return Icons.air_rounded;
      case 2:
        return Icons.power_settings_new_rounded;
      case 3:
        return Icons.electrical_services_rounded;
      default:
        return Icons.devices_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = device['name']?.toString() ?? 'Device';
    final id = device['id']?.toString() ?? '';
    final type = device['type'] is num ? (device['type'] as num).toInt() : 0;
    final state = device['state'] as bool? ?? false;
    final moduleId = (device['moduleId'] ?? device['expanderId'] ?? 'io_1')
        .toString();
    final rawChannel = device['channel'];
    final channel = rawChannel is num
        ? rawChannel.toInt()
        : int.tryParse(rawChannel?.toString() ?? '') ?? -1;
    final color = state ? _DT.amber : Colors.grey;

    void showOptions() {
      if (id.isNotEmpty) onOptions(id, name, moduleId, channel);
    }

    return HomeCard(
      padding: const EdgeInsets.all(6),
      child: InkWell(
        onLongPress: showOptions,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _iconFor(type),
              size: 25,
              color: color,
              shadows: [Shadow(color: color, blurRadius: 12)],
            ),
            const SizedBox(height: 5),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    pending
                        ? '…'
                        : state
                        ? 'On'
                        : 'Off',
                    style: TextStyle(
                      fontSize: 9,
                      color: state
                          ? const Color(0xFF36D799)
                          : const Color(0xFFA5B4D0),
                    ),
                  ),
                ),
                SizedBox(
                  width: 30,
                  height: 24,
                  child: FittedBox(
                    child: Switch(
                      value: state,
                      onChanged: pending || id.isEmpty
                          ? null
                          : (v) => unawaited(onToggle(id, v)),
                      activeTrackColor: const Color(0xFF26CD75),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 24. OPTION TILE
// ────────────────────────────────────────────────────────────
class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? _DT.purple),
      title: Text(title, style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
      ),
      onTap: onTap,
    );
  }
}

// ────────────────────────────────────────────────────────────
// 25. GLASS CARD
// ────────────────────────────────────────────────────────────
class _GCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? glowColor;
  final bool dangerBorder;

  const _GCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.glowColor,
    this.dangerBorder = false,
  });

  @override
  Widget build(BuildContext context) => HomeCard(
    padding: padding,
    glowColor: dangerBorder ? Theme.of(context).colorScheme.error : glowColor,
    child: child,
  );
}

// ────────────────────────────────────────────────────────────
// 26. PILL BUTTON
// ────────────────────────────────────────────────────────────
class _PillBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _PillBtn({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        gradient: const LinearGradient(colors: [Color(0xFF8B7FFF), _DT.purple]),
        boxShadow: [
          BoxShadow(color: _DT.purple.withValues(alpha: 0.35), blurRadius: 14),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

// ────────────────────────────────────────────────────────────
// 27. GLASS BOTTOM NAV
// ────────────────────────────────────────────────────────────

class _EnergyScreen extends ConsumerWidget {
  const _EnergyScreen();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(httpDataProvider).asData?.value['energy'];
    return ReferenceEnergy(
      data: e is Map ? e : {},
      onSettings: () => ref.read(selectedNavIndexProvider.notifier).state = 3,
    );
  }
}

class _AlertsScreen extends ConsumerWidget {
  const _AlertsScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);
    final notifications = ref.watch(appNotificationsProvider);
    final unreadCount = notifications.where((item) => !item.read).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
      children: [
        HomeHero(
          title: 'Notifications',
          subtitle: '$unreadCount unread notifications',
          trailing: IconButton(
            tooltip: 'Settings',
            onPressed: () =>
                ref.read(selectedNavIndexProvider.notifier).state = 3,
            icon: const Icon(Icons.settings_outlined),
          ),
        ),
        if (notifications.isNotEmpty)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () =>
                    ref.read(appNotificationsProvider.notifier).markAllRead(),
                icon: const Icon(Icons.check, size: 15),
                label: const Text(
                  'Mark all read',
                  style: TextStyle(fontSize: 10),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    ref.read(appNotificationsProvider.notifier).clearAll(),
                icon: const Icon(Icons.delete_outline, size: 15),
                label: const Text('Clear', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        if (notifications.isEmpty)
          _GCard(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _DT.green.withValues(alpha: 0.14),
                  ),
                  child: const Icon(
                    Icons.notifications_none_rounded,
                    color: _DT.green,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'No notifications yet',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Device changes, ESP online/offline events, Bluetooth backup status, and flame alerts will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          )
        else
          for (final read in [false, true]) ...[
            if (notifications.any((n) => n.read == read))
              HomeSection(read ? 'Earlier' : 'Unread'),
            ...notifications
                .where((n) => n.read == read)
                .map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _NotificationTile(item: item),
                  ),
                ),
          ],
      ],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotificationItem item;
  const _NotificationTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final category = item.title.toLowerCase().contains('flame')
        ? 'Safety'
        : item.title.toLowerCase().contains('bluetooth')
        ? 'Connectivity'
        : item.title.toLowerCase().contains('light')
        ? 'Device'
        : 'System';
    return HomeCard(
      padding: const EdgeInsets.all(10),
      glowColor: item.read ? null : item.color,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HomeGlowIcon(item.icon, color: item.color, size: 46),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _timeAgo(item.createdAt),
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFFA8BADA),
                      ),
                    ),
                    if (!item.read)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(Icons.circle, color: item.color, size: 7),
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  item.message,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: Color(0xFFA8BADA),
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: item.color.withValues(alpha: .6)),
                  ),
                  child: Text(
                    category,
                    style: TextStyle(color: item.color, fontSize: 9),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 30. SETTINGS SCREEN
// ────────────────────────────────────────────────────────────
class _SettingsScreen extends ConsumerWidget {
  const _SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final bleStatus = ref.watch(bleServiceProvider).currentStatus;
    final esp32CodeAsync = ref.watch(userEsp32CodeProvider);
    final authService = ref.watch(authServiceProvider).asData?.value;
    if (authService == null)
      return const Center(child: CircularProgressIndicator());
    final user = authService.currentUser;
    final assistantName =
        ref.watch(assistantNameProvider).asData?.value ?? defaultAssistantName;

    void onConnectBLE() {
      unawaited(ref.read(bleServiceProvider).connect().catchError((_) {}));
    }

    Future<void> onRefresh() async {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        await ble.refreshDevices().catchError((_) {});
      }
      ref.invalidate(httpDataProvider);
    }

    Future<bool> syncAssistantNameToController(String name) async {
      final esp32Ip = await _resolveAssistantEsp32Ip(ref);
      try {
        final response = await http
            .post(
              Uri.parse('http://$esp32Ip/api/assistant/name'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'assistantName': name}),
            )
            .timeout(const Duration(milliseconds: 1500));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return true;
        }
      } catch (_) {
        // Use BLE when the controller is not reachable over the local network.
      }

      final ble = ref.read(bleServiceProvider);
      if (!ble.isConnected) return false;
      try {
        return await ble.setAssistantName(name);
      } catch (_) {
        return false;
      }
    }

    void showEditCodeDialog() {
      final rootContext = context;
      final TextEditingController codeController = TextEditingController(
        text: esp32CodeAsync.value ?? '',
      );

      showDialog(
        context: rootContext,
        builder: (dialogContext) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: Colors.transparent,
          child: _GCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _DT.purple.withValues(alpha: 0.15),
                  ),
                  child: const Icon(
                    Icons.nfc_rounded,
                    color: _DT.purple,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'ESP32 Unique Code',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter the unique code of your ESP32',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: codeController,
                  decoration: InputDecoration(
                    hintText: 'e.g. ESP32-ABCD-1234',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(
                          dialogContext,
                        ).colorScheme.onSurface.withValues(alpha: 0.1),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _DT.purple, width: 2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          final newCode = codeController.text.trim();
                          if (newCode.isNotEmpty && user != null) {
                            try {
                              await authService.updateEsp32Code(
                                user.uid,
                                newCode,
                              );
                              ref.invalidate(userEsp32CodeProvider);
                              Navigator.pop(dialogContext);
                              if (rootContext.mounted)
                                _showSnack(
                                  rootContext,
                                  '✅ ESP32 Code updated to $newCode',
                                  color: _DT.green,
                                );
                            } catch (e) {
                              if (rootContext.mounted)
                                _showSnack(
                                  rootContext,
                                  '❌ Failed to update Code: ${e.toString()}',
                                  color: _DT.red,
                                );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _DT.purple,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text(
                          'Update Code',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    void showAssistantNameDialog() {
      final rootContext = context;
      final nameController = TextEditingController(text: assistantName);
      String? validationError;

      showDialog<void>(
        context: rootContext,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            backgroundColor: Colors.transparent,
            child: _GCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [_DT.purple, _DT.blue],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _DT.purple.withValues(alpha: 0.3),
                          blurRadius: 22,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.graphic_eq_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Voice Assistant Name',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Saved only on this device and used by the local wake phrase and ESP32 commands.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.58),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    maxLength: 24,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Assistant name',
                      hintText: 'e.g. Nova, Noor, Home Mate',
                      errorText: validationError,
                      prefixIcon: const Icon(Icons.mic_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onSubmitted: (_) {},
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            final nextName = compactAssistantName(
                              nameController.text,
                            );
                            final error = validateAssistantName(nextName);
                            if (error != null) {
                              setDialogState(() => validationError = error);
                              return;
                            }
                            try {
                              await ref
                                  .read(assistantNameStoreProvider)
                                  .save(nextName);
                              final synced =
                                  await syncAssistantNameToController(nextName);
                              ref.invalidate(assistantNameProvider);
                              if (!dialogContext.mounted) return;
                              Navigator.pop(dialogContext);
                              if (rootContext.mounted) {
                                _showSnack(
                                  rootContext,
                                  synced
                                      ? 'Voice assistant renamed to $nextName on the app and ESP32'
                                      : 'Name saved. ESP32 sync will retry when the assistant opens.',
                                  color: synced ? _DT.green : _DT.amber,
                                );
                              }
                            } catch (error) {
                              if (rootContext.mounted) {
                                _showSnack(
                                  rootContext,
                                  'Could not update the assistant name: $error',
                                  color: _DT.red,
                                );
                              }
                            }
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: _DT.purple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Save name'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ).whenComplete(nameController.dispose);
    }

    void showTestConnectionDialog() async {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: Colors.transparent,
          child: _GCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(color: _DT.purple),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Testing Connection...',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please wait while we test the connection to ESP32',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      try {
        final esp32Service = await ref.read(esp32DeviceServiceProvider.future);
        final devices = await esp32Service.getDevices();
        Navigator.pop(context);

        final isConnected = devices['devices'] != null;

        showDialog(
          context: context,
          builder: (context) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            backgroundColor: Colors.transparent,
            child: _GCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (isConnected ? _DT.green : _DT.red).withValues(
                        alpha: 0.15,
                      ),
                    ),
                    child: Icon(
                      isConnected ? Icons.check_rounded : Icons.close_rounded,
                      color: isConnected ? _DT.green : _DT.red,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isConnected ? '✅ Connected!' : '❌ Connection Failed',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: isConnected ? _DT.green : _DT.red,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isConnected
                        ? 'ESP32 is reachable via code ${esp32CodeAsync.value ?? "Unknown"}'
                        : 'Could not reach ESP32 with code ${esp32CodeAsync.value ?? "Unknown"}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (isConnected) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Found ${(devices['devices'] as List?)?.length ?? 0} devices',
                      style: TextStyle(fontSize: 14, color: _DT.purple),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } catch (e) {
        Navigator.pop(context);
        showDialog(
          context: context,
          builder: (context) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            backgroundColor: Colors.transparent,
            child: _GCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _DT.red.withValues(alpha: 0.15),
                    ),
                    child: const Icon(
                      Icons.error_rounded,
                      color: _DT.red,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '❌ Connection Error',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: _DT.red,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Error: ${e.toString()}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    void showSignOutDialog() {
      final rootContext = context;
      showDialog(
        context: rootContext,
        builder: (dialogContext) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: Colors.transparent,
          child: _GCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _DT.red.withValues(alpha: 0.15),
                  ),
                  child: const Icon(
                    Icons.logout_rounded,
                    color: _DT.red,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Sign Out',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Are you sure you want to sign out?',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          try {
                            await authService.signOut();
                            ref.read(selectedNavIndexProvider.notifier).state =
                                0;
                            ref.invalidate(assistantNameProvider);
                            ref.invalidate(userDataProvider);
                            ref.invalidate(userEsp32CodeProvider);
                            ref.invalidate(httpDataProvider);
                            if (rootContext.mounted) {
                              Navigator.of(
                                rootContext,
                                rootNavigator: true,
                              ).pushNamedAndRemoveUntil(
                                '/login',
                                (route) => false,
                              );
                            }
                          } catch (e) {
                            if (rootContext.mounted) {
                              _showSnack(
                                rootContext,
                                'Failed to sign out: $e',
                                color: _DT.red,
                              );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _DT.red,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Sign Out'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final esp32Code = esp32CodeAsync.asData?.value;
    final connected =
        bleStatus == BleStatus.connected || bleStatus == BleStatus.dataUpdated;
    Widget row(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback? tap, {
      Color color = HomeDesign.blue,
      String? action,
    }) => HomeSettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: tap,
      color: color,
      action: action,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      children: [
        const HomeHero(
          title: 'Settings',
          subtitle: 'Customize your smart home experience',
        ),
        ReferenceGroup(
          title: 'APPEARANCE',
          subtitle: 'Choose how the app looks.',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                for (final (i, item) in [
                  (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                  (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
                  (ThemeMode.system, 'System', Icons.desktop_windows_outlined),
                ].indexed) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: ReferenceChoice(
                      label: item.$2,
                      icon: item.$3,
                      selected: themeMode == item.$1,
                      onTap: () =>
                          ref.read(themeModeProvider.notifier).state = item.$1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        ReferenceGroup(
          title: 'DEVICE & VOICE',
          subtitle: 'Manage your connected devices.',
          child: Column(
            children: [
              row(
                Icons.mic_none,
                'Voice assistant',
                'Wake name: $assistantName',
                showAssistantNameDialog,
                color: HomeDesign.violet,
                action: 'Rename',
              ),
              const Divider(),
              row(
                Icons.bluetooth,
                'Bluetooth',
                connected ? 'Connected to smart devices' : 'Tap to connect',
                connected ? null : onConnectBLE,
                action: connected ? '● Connected' : null,
              ),
              const Divider(),
              row(
                Icons.refresh,
                'Manual refresh',
                'Sync all devices and update status',
                () => unawaited(onRefresh()),
                action: 'Refresh Now',
              ),
            ],
          ),
        ),
        ReferenceGroup(
          title: 'ESP32 SETTINGS',
          subtitle: 'Configure your ESP32 device.',
          child: Row(
            children: [
              Expanded(
                child: row(
                  Icons.memory,
                  'ESP32 Settings',
                  esp32Code ?? 'Controller code unavailable',
                  showEditCodeDialog,
                  color: const Color(0xFF19DCA3),
                  action: 'Edit Code',
                ),
              ),
              TextButton(
                onPressed: showTestConnectionDialog,
                child: const Text('Test', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        ),
        ReferenceGroup(
          title: 'ACCOUNT',
          subtitle: 'Manage your account.',
          child: row(
            Icons.logout,
            'Sign out',
            'Sign out from this device',
            showSignOutDialog,
            color: _DT.red,
          ),
        ),
        ReferenceGroup(
          title: 'SYSTEM',
          subtitle: 'Advanced configuration and information.',
          child: Column(
            children: [
              row(
                Icons.link,
                'Provision ESP32',
                'Set up a new ESP32 device',
                () => Navigator.pushNamed(context, '/provision'),
                color: HomeDesign.cyan,
              ),
              const Divider(),
              row(
                Icons.wifi,
                'Wi-Fi manager',
                'Configure Wi-Fi network settings',
                () => Navigator.pushNamed(context, '/wifiConfig'),
                color: HomeDesign.cyan,
              ),
              const Divider(),
              row(
                Icons.view_in_ar_outlined,
                'I/O modules',
                'Manage connected I/O modules',
                () => Navigator.pushNamed(context, '/ioModules'),
                color: HomeDesign.violet,
              ),
              const Divider(),
              row(
                Icons.info_outline,
                'About',
                'App version, licenses and more',
                () => showAboutDialog(
                  context: context,
                  applicationName: 'Smart Home',
                  applicationVersion: '2.11.0',
                  applicationIcon: const HomeGlowIcon(Icons.home_outlined),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────
// 31. SKELETON LOADER
// ────────────────────────────────────────────────────────────
class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    return Shimmer.fromColors(
      baseColor: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.07),
      highlightColor: isDark
          ? Colors.white.withValues(alpha: 0.12)
          : Colors.black.withValues(alpha: 0.03),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          top: 12,
          left: padding,
          right: padding,
          bottom: 24,
        ),
        child: const Column(
          children: [
            _SBox(h: 54, r: 16),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _SBox(h: 90, r: 20)),
                SizedBox(width: 10),
                Expanded(child: _SBox(h: 90, r: 20)),
                SizedBox(width: 10),
                Expanded(child: _SBox(h: 90, r: 20)),
              ],
            ),
            SizedBox(height: 12),
            _SBox(h: 64, r: 16),
            SizedBox(height: 12),
            _SBox(h: 40, r: 16),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _SBox(h: 160, r: 20)),
                SizedBox(width: 12),
                Expanded(child: _SBox(h: 160, r: 20)),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _SBox(h: 160, r: 20)),
                SizedBox(width: 12),
                Expanded(child: _SBox(h: 160, r: 20)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SBox extends StatelessWidget {
  final double h;
  final double r;
  const _SBox({required this.h, required this.r});

  @override
  Widget build(BuildContext context) => Container(
    height: h,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(r),
    ),
  );
}
