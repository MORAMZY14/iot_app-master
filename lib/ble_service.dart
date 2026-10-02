import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_logger.dart';
import 'app_constants.dart';
import 'auth_service.dart';
import 'network/foreground_poller.dart';

// Must match the ESP32 BLE backup firmware.
const String esp32DeviceName = 'ESP32_SmartHome';
const String serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String commandCharUuid = 'd8e3b8a2-4f5c-4b6e-9a2f-1a2b3c4d5e6f';

// Backwards-compatible aliases used by older dashboard code.
const String sensorCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const String lightCharUuid = commandCharUuid;

/// Only firmware replies can finish a command. A queued write is itself JSON
/// with the command/requestId, but has no boolean `ok` response envelope.
Map<String, dynamic>? decodeBleCommandResponse(
  List<int> value, {
  required String requestId,
  required String expectedCmd,
  required int baselineSequence,
}) {
  final text = utf8.decode(value, allowMalformed: true).trim();
  if (text.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic> || decoded['ok'] is! bool) return null;
  final responseRequestId = decoded['requestId']?.toString();
  if (responseRequestId != null && responseRequestId != requestId) return null;
  final sequence = decoded['responseSequence'];
  if (sequence is num && sequence.toInt() <= baselineSequence) return null;
  final responseCmd = (decoded['cmd'] ?? '').toString();
  if (expectedCmd.isNotEmpty && responseCmd.isNotEmpty && responseCmd != expectedCmd) {
    return null;
  }
  return decoded;
}

final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService(controllerCode: () => ref.read(userEsp32CodeProvider.future));
  ref.listen(authUserProvider, (previous, next) {
    if (next.asData != null && previous?.asData?.value?.uid != next.asData!.value?.uid) {
      unawaited(service.disconnect());
    }
  });
  ref.onDispose(service.dispose);
  return service;
});

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _commandChar;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Completer<BluetoothDevice?>? _pendingScan;
  Future<void>? _connectFuture;
  Future<void> _commandTail = Future<void>.value();
  ForegroundPoller? _sensorPoller;
  bool _disposed = false;
  bool _commandBusy = false;
  bool _verifyingIdentity = false;
  final Future<String?> Function()? _controllerCode;
  int _lastResponseSequence = 0;
  int _connectionGeneration = 0;
  int _requestSequence = 0;

  double temperature = 0.0;
  double humidity = 0.0;
  bool flameDetected = false;
  String? controllerIp;
  String? controllerUniqueCode;
  String? controllerAssistantName;
  String? controllerFirmwareVersion;
  bool assistantReady = false;
  Map<String, bool> lights = <String, bool>{};
  List<Map<String, dynamic>> devices = <Map<String, dynamic>>[];

  final _stateController = StreamController<BleStatus>.broadcast();
  Stream<BleStatus> get statusStream => _stateController.stream;

  BleStatus _currentStatus = BleStatus.disconnected;
  BleStatus get currentStatus => _currentStatus;
  bool get isConnected =>
      _currentStatus == BleStatus.connected ||
      _currentStatus == BleStatus.dataUpdated;

  bool _isUserCancelledBluetoothError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('notfounderror') ||
        message.contains('user cancelled') ||
        message.contains('user canceled') ||
        message.contains('cancelled the requestdevice') ||
        message.contains('canceled the requestdevice') ||
        message.contains('requestdevice() chooser') ||
        message.contains('bluetooth device chooser');
  }

  BleService({Stream<BluetoothAdapterState>? adapterStates, Future<String?> Function()? controllerCode})
      : _controllerCode = controllerCode {
    _adapterSub = (adapterStates ?? FlutterBluePlus.adapterState).listen((state) {
      if (_disposed) return;
      if (state != BluetoothAdapterState.on) {
        unawaited(_disconnect());
        _updateStatus(BleStatus.adapterOff);
      } else if (_currentStatus == BleStatus.adapterOff) {
        _updateStatus(BleStatus.disconnected);
      }
    }, onError: (Object error, StackTrace stack) {
      if (_disposed) return;
      logDebug('BLE adapter stream failed (${error.runtimeType}).');
      unawaited(_disconnect());
      _updateStatus(BleStatus.error);
    });
  }

  Future<void> connect() async {
    if (_disposed || isConnected) return;
    final pending = _connectFuture;
    if (pending != null) {
      await pending;
      return;
    }
    final connection = _connect();
    _connectFuture = connection;
    try {
      await connection;
    } finally {
      if (identical(_connectFuture, connection)) _connectFuture = null;
    }
  }

  bool _isCurrentConnection(int generation) =>
      !_disposed && generation == _connectionGeneration;

  Future<void> _connect() async {
    final generation = ++_connectionGeneration;
    _clearControllerData();
    _updateStatus(BleStatus.scanning);

    StreamSubscription<List<ScanResult>>? scanSub;
    final foundDevice = Completer<BluetoothDevice?>();
    _pendingScan = foundDevice;
    BluetoothDevice? selectedDevice;
    Object? scanError;

    try {
      await _safeStopScan();
      if (!_isCurrentConnection(generation)) return;

      scanSub = FlutterBluePlus.scanResults.listen(
        (results) {
          if (!_isCurrentConnection(generation)) return;
          for (final result in results) {
            final name = result.device.platformName.isNotEmpty
                ? result.device.platformName
                : result.advertisementData.advName;
            final hasService = result.advertisementData.serviceUuids
                .map((e) => e.toString().toLowerCase())
                .contains(serviceUuid.toLowerCase());

            if ((name == esp32DeviceName || hasService) &&
                !foundDevice.isCompleted) {
              foundDevice.complete(result.device);
              break;
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!foundDevice.isCompleted) {
            // Complete normally so an error arriving while startScan() is
            // awaiting the browser chooser cannot become an unhandled Future.
            scanError = error;
            foundDevice.complete(null);
          }
        },
      );
      _scanSub = scanSub;

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 4),
        withServices: kIsWeb ? [Guid(serviceUuid)] : [],
      );

      if (!_isCurrentConnection(generation)) return;
      selectedDevice = await foundDevice.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (scanError != null) throw scanError!;
    } catch (e) {
      if (!_isCurrentConnection(generation)) return;
      // On Flutter Web, closing/cancelling the browser Bluetooth chooser throws
      // NotFoundError. This is a normal user action, not a real app error.
      if (_isUserCancelledBluetoothError(e)) {
        logDebug('BLE scan cancelled by user: $e');
        _updateStatus(BleStatus.disconnected);
        return;
      }
      logDebug('BLE scan error: $e');
      _updateStatus(BleStatus.error);
      return;
    } finally {
      await scanSub?.cancel();
      if (identical(_scanSub, scanSub)) _scanSub = null;
      if (identical(_pendingScan, foundDevice)) _pendingScan = null;
      await _safeStopScan();
    }

    if (!_isCurrentConnection(generation)) return;
    if (selectedDevice == null) {
      _updateStatus(BleStatus.notFound);
      return;
    }

    final device = selectedDevice;
    _device = device;
    _updateStatus(BleStatus.connecting);
    try {
      await device
          .connect(autoConnect: false, timeout: const Duration(seconds: 6))
          .timeout(const Duration(seconds: 8));
      if (!_isCurrentConnection(generation)) {
        await device.disconnect(queue: false, timeout: 3).timeout(
          const Duration(seconds: 6),
        );
        return;
      }
      await _connectionSub?.cancel();
      if (!_isCurrentConnection(generation)) return;
      _connectionSub = device.connectionState.listen((state) {
        if (!_isCurrentConnection(generation)) return;
        if (state == BluetoothConnectionState.disconnected) {
          unawaited(_disconnect());
          _updateStatus(BleStatus.disconnected);
        }
      }, onError: (Object error, StackTrace stack) {
        if (!_isCurrentConnection(generation)) return;
        logDebug('BLE connection stream failed (${error.runtimeType}).');
        unawaited(_disconnect());
        _updateStatus(BleStatus.error);
      });

      final services = await device.discoverServices(timeout: 6).timeout(
        const Duration(seconds: 8),
      );
      if (!_isCurrentConnection(generation)) return;
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() != serviceUuid.toLowerCase())
          continue;
        for (final char in service.characteristics) {
          final uuid = char.uuid.toString().toLowerCase();
          if (uuid == commandCharUuid.toLowerCase()) {
            _commandChar = char;
          }
        }
      }

      if (_commandChar == null) {
        throw StateError('BLE backup command characteristic not found');
      }

      _lastResponseSequence = 0;
      _verifyingIdentity = _controllerCode != null;
      _updateStatus(BleStatus.connected);
      if (_controllerCode != null) {
        final expectedCode = await _controllerCode();
        if (!_isCurrentConnection(generation)) return;
        await readControllerStatus();
        if (!_isCurrentConnection(generation)) return;
        if (expectedCode != null && controllerUniqueCode != expectedCode) {
          throw StateError('This Bluetooth controller does not match your linked ESP32.');
        }
      }
      _verifyingIdentity = false;
      await readSensorData();
      if (!_isCurrentConnection(generation)) return;
      // Finish the initial device read before connect() returns. Starting this
      // unawaited raced the first assistant command and made it look as though
      // the ESP32 had frozen while Flutter rejected the overlapping command.
      await refreshDevices();
      if (_isCurrentConnection(generation)) _startSensorPolling();
    } catch (e) {
      if (!_isCurrentConnection(generation)) return;
      if (_isUserCancelledBluetoothError(e)) {
        logDebug('BLE connection cancelled by user: $e');
        await _disconnect();
        _updateStatus(BleStatus.disconnected);
        return;
      }
      logDebug('BLE connection error: $e');
      await _disconnect();
      _updateStatus(BleStatus.error);
    }
  }

  Future<Map<String, dynamic>> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = AppConfig.mediumTimeout,
  }) async {
    final characteristic = _commandChar;
    final generation = _connectionGeneration;
    if (_disposed || !isConnected || characteristic == null) {
      throw StateError('BLE is not connected');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive');
    }
    final expectedCmd = (command['cmd'] ?? '').toString();
    if (_verifyingIdentity && expectedCmd != 'status') {
      throw StateError('Wait for the Bluetooth controller to be verified.');
    }
    final requestId = '${generation}_${++_requestSequence}';
    // Snapshot the payload now; callers may mutate their map while queued.
    final encodedCommand = utf8.encode(
      jsonEncode({...command, 'requestId': requestId}),
    );
    if (encodedCommand.length > 511) {
      throw const FormatException(
        'Command is too long for Bluetooth. Use a shorter message.',
      );
    }

    void ensureConnected() {
      if (!_isCurrentConnection(generation) ||
          !isConnected ||
          !identical(_commandChar, characteristic)) {
        throw StateError('The BLE connection changed during the command');
      }
    }

    // One GATT read/write exchange at a time, including background polling.
    // A failed command completes the tail normally so later work can recover.
    final previous = _commandTail;
    final result = previous.then((_) async {
      ensureConnected();
      _commandBusy = true;
      final elapsed = Stopwatch()..start();
      Future<T> bounded<T>(Future<T> Function(int) operation) {
        final remaining = timeout - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('BLE command timed out');
        }
        final seconds = (remaining.inMilliseconds + 999) ~/ 1000;
        return operation(seconds < 1 ? 1 : seconds).timeout(remaining);
      }

      try {
        var baselineSequence = _lastResponseSequence;
        try {
          final before = await bounded((seconds) => characteristic.read(timeout: seconds));
          ensureConnected();
          final beforeText = utf8.decode(before, allowMalformed: true).trim();
          if (beforeText.isNotEmpty) {
            final decoded = jsonDecode(beforeText);
            if (decoded is Map && decoded['responseSequence'] is num) {
              final sequence = (decoded['responseSequence'] as num).toInt();
              if (sequence > baselineSequence) baselineSequence = sequence;
              if (sequence > _lastResponseSequence) {
                _lastResponseSequence = sequence;
              }
            }
          }
        } on FormatException {
          // Older firmware can start with an empty or non-JSON value.
        }
        ensureConnected();
        await bounded((seconds) => characteristic.write(
          encodedCommand,
          withoutResponse: false,
          // NimBLE firmware accepts a complete prepared write. Native iOS
          // MTUs can be smaller than an assistant or Wi-Fi credentials JSON.
          allowLongWrite: !kIsWeb,
          timeout: seconds,
        ));
        ensureConnected();

        while (elapsed.elapsed < timeout) {
          await bounded((_) => Future<void>.delayed(const Duration(milliseconds: 60)));
          ensureConnected();
          final value = await bounded((seconds) => characteristic.read(timeout: seconds));
          ensureConnected();
          final decoded = decodeBleCommandResponse(
            value,
            requestId: requestId,
            expectedCmd: expectedCmd,
            baselineSequence: baselineSequence,
          );
          if (decoded == null) continue;
          final rawSequence = decoded['responseSequence'];
          if (rawSequence is num) {
            _lastResponseSequence = rawSequence.toInt();
          }
          if (decoded['ok'] == false) {
            throw Exception(decoded['error'] ?? decoded['message'] ?? 'BLE command failed');
          }
          return decoded;
        }
        throw TimeoutException('BLE command timed out');
      } on TimeoutException {
        // Future.timeout cannot cancel a native GATT operation. Close this
        // connection before another queued command can reuse its transport.
        final cleanup = _disconnect();
        _updateStatus(BleStatus.error);
        await cleanup;
        rethrow;
      } finally {
        elapsed.stop();
        _commandBusy = false;
      }
    });
    _commandTail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _startSensorPolling() {
    _sensorPoller?.dispose();
    _sensorPoller = ForegroundPoller(
      interval: const Duration(seconds: 8),
      onPoll: () async {
        if (!_disposed && isConnected && !_commandBusy) await readSensorData();
      },
    )..start();
  }

  Future<void> readSensorData() async {
    if (!isConnected) return;
    final generation = _connectionGeneration;
    try {
      final data = await readControllerStatus();
      if (!_isCurrentConnection(generation)) return;
      final temp = data['temp'] ?? data['temperature'];
      final hum = data['hum'] ?? data['humidity'];
      final flame = data['flame'];
      if (temp is num) temperature = temp.toDouble();
      if (hum is num) humidity = hum.toDouble();
      if (flame is bool) flameDetected = flame;
      _updateStatus(BleStatus.dataUpdated);
    } catch (e) {
      logDebug('BLE status read skipped: $e');
    }
  }

  Future<Map<String, dynamic>> readControllerStatus() async {
    final generation = _connectionGeneration;
    final data = await sendCommand({
      'cmd': 'status',
    }, timeout: AppConfig.shortTimeout);
    if (!_isCurrentConnection(generation)) {
      throw StateError('The BLE connection changed during the status read');
    }
    final ip = (data['ip'] ?? '').toString().trim();
    controllerIp = ip.isNotEmpty && ip != '0.0.0.0' && ip != 'BLE' ? ip : null;
    final code = (data['uniqueCode'] ?? '').toString().trim();
    if (code.isNotEmpty) controllerUniqueCode = code;
    final name = (data['assistantName'] ?? '').toString().trim();
    controllerAssistantName = name.isEmpty ? null : name;
    final version = (data['firmwareVersion'] ?? '').toString().trim();
    if (version.isNotEmpty) controllerFirmwareVersion = version;
    assistantReady = data['assistantReady'] == true;
    return data;
  }

  Future<void> refreshDevices() async {
    if (!isConnected) return;
    final generation = _connectionGeneration;
    try {
      final response = await sendCommand({
        'cmd': 'get_devices',
      }, timeout: AppConfig.mediumTimeout);
      if (!_isCurrentConnection(generation)) return;
      final rawDevices = response['devices'];
      if (rawDevices is List) {
        devices = rawDevices.whereType<Map>().map((e) {
          final map = e.cast<String, dynamic>();
          return map;
        }).toList();
        lights = <String, bool>{};
        for (final d in devices) {
          // Device ID is unique; room is not. Using room as the key caused two
          // relays in the same room to overwrite each other's displayed state.
          final key = (d['id'] ?? '').toString();
          if (key.isNotEmpty) lights[key] = d['state'] == true;
        }
      }
      _updateStatus(BleStatus.dataUpdated);
    } catch (e) {
      logDebug('BLE get devices skipped: $e');
    }
  }

  Future<void> readLightStates() => refreshDevices();

  /// Sends a deterministic Ellie command through the ESP32's existing BLE
  /// parser. The assistant has no remote conversation path.
  Future<Map<String, dynamic>> sendEllieText(
    String text, {
    required bool speak,
    required String assistantName,
  }) {
    return sendCommand({
      'cmd': 'ellie',
      'text': text,
      'speak': speak,
      'assistantName': assistantName,
    }, timeout: AppConfig.longTimeout);
  }

  /// Persists the customer-selected wake name in ESP32 NVS over local BLE.
  Future<bool> setAssistantName(String assistantName) async {
    final response = await sendCommand({
      'cmd': 'set_assistant_name',
      'assistantName': assistantName,
    }, timeout: AppConfig.mediumTimeout);
    return response['ok'] == true;
  }

  Future<bool> queueEllieSpeech(String text) async {
    final response = await sendCommand({
      'cmd': 'ellie_speak',
      'text': text,
    }, timeout: AppConfig.mediumTimeout);
    return response['speakerQueued'] == true || response['ok'] == true;
  }

  Future<void> disconnect() async {
    final pending = _disconnect();
    _updateStatus(BleStatus.disconnected);
    await pending;
  }

  Future<bool> controlDevice({required String id, required bool state}) async {
    final generation = _connectionGeneration;
    final response = await sendCommand({
      'cmd': 'set_device',
      'id': id,
      'state': state,
    }, timeout: AppConfig.bleControlTimeout);
    if (!_isCurrentConnection(generation)) return false;
    if (response['ok'] == true) {
      for (final d in devices) {
        if ((d['id'] ?? '').toString() == id) {
          d['state'] = state;
          final deviceId = (d['id'] ?? '').toString();
          if (deviceId.isNotEmpty) lights[deviceId] = state;
        }
      }
      _updateStatus(BleStatus.dataUpdated);
      return true;
    }
    return false;
  }

  Future<void> setLightState(String room, bool state) async {
    final generation = _connectionGeneration;
    final response = await sendCommand({
      'cmd': 'set_room',
      'room': room,
      'state': state,
    }, timeout: AppConfig.bleControlTimeout);
    if (!_isCurrentConnection(generation)) return;
    if (response['ok'] == true) {
      for (final device in devices) {
        if (device['room']?.toString() != room) continue;
        device['state'] = state;
        final id = (device['id'] ?? '').toString();
        if (id.isNotEmpty) lights[id] = state;
      }
      _updateStatus(BleStatus.dataUpdated);
    }
  }

  Future<bool> editOutput(String id, String moduleId, int channel) async {
    final response = await sendCommand({
      'cmd': 'edit_output',
      'id': id,
      'moduleId': moduleId,
      'channel': channel,
    }, timeout: AppConfig.mediumTimeout);
    return response['ok'] == true;
  }

  Future<bool> editChannel(String id, int channel) =>
      editOutput(id, 'io_1', channel);

  Future<bool> requestDeviceSync() async {
    final response = await sendCommand({
      'cmd': 'sync_devices',
    }, timeout: AppConfig.mediumTimeout);
    return response['ok'] == true;
  }

  Future<bool> connectWifi(String ssid, String password) async {
    final response = await sendCommand({
      'cmd': 'wifi_connect',
      'ssid': ssid,
      'password': password,
    }, timeout: AppConfig.mediumTimeout);
    return response['ok'] == true;
  }

  Future<List<Map<String, dynamic>>> scanWifi() async {
    final response = await sendCommand({
      'cmd': 'wifi_scan',
    }, timeout: const Duration(seconds: 10));

    final networks = response['networks'];
    if (networks is List) {
      return networks
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  Future<bool> forgetWifi() async {
    try {
      final response = await sendCommand({
        'cmd': 'forget_wifi',
      }, timeout: AppConfig.mediumTimeout);
      return response['ok'] == true;
    } catch (_) {
      // Older experimental firmware used wifi_forget. Keep this fallback so
      // mixed app/firmware versions do not fail at compile/runtime.
      final response = await sendCommand({
        'cmd': 'wifi_forget',
      }, timeout: AppConfig.mediumTimeout);
      return response['ok'] == true;
    }
  }

  Future<void> _safeStopScan() async {
    try {
      final scanning = await FlutterBluePlus.isScanning.first.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () => false,
      );
      if (scanning) {
        await FlutterBluePlus.stopScan().timeout(const Duration(seconds: 2));
      }
    } catch (e) {
      // FlutterBluePlus may print "already stopped" on some platforms. It is harmless.
      logDebug('BLE stopScan ignored: $e');
    }
  }

  void _clearControllerData() {
    temperature = 0;
    humidity = 0;
    flameDetected = false;
    controllerIp = null;
    controllerUniqueCode = null;
    controllerAssistantName = null;
    controllerFirmwareVersion = null;
    assistantReady = false;
    lights = <String, bool>{};
    devices = <Map<String, dynamic>>[];
  }

  Future<void> _disconnect() async {
    _connectionGeneration++;
    _verifyingIdentity = false;
    _sensorPoller?.dispose();
    _sensorPoller = null;
    final scan = _scanSub;
    _scanSub = null;
    final pendingScan = _pendingScan;
    _pendingScan = null;
    if (pendingScan != null && !pendingScan.isCompleted) pendingScan.complete(null);
    final connection = _connectionSub;
    _connectionSub = null;
    _lastResponseSequence = 0;
    final device = _device;
    _device = null;
    _commandChar = null;
    _clearControllerData();
    try {
      await Future.wait<void>([
        if (scan != null) scan.cancel(),
        if (connection != null) connection.cancel(),
        if (scan != null || pendingScan != null) _safeStopScan(),
        // Bypass FBP's global GATT queue so a stuck operation cannot block
        // cancellation. Keep its Android minimum disconnect delay intact.
        if (device != null) device.disconnect(queue: false, timeout: 3).timeout(
          const Duration(seconds: 6),
        ),
      ]);
    } catch (error) {
      logDebug('BLE connection cleanup failed (${error.runtimeType}).');
    }
  }

  void _updateStatus(BleStatus status) {
    if (_disposed) return;
    _currentStatus = status;
    if (!_stateController.isClosed) {
      _stateController.add(status);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _currentStatus = BleStatus.disconnected;
    final adapter = _adapterSub;
    _adapterSub = null;
    if (adapter != null) {
      unawaited(adapter.cancel().catchError((Object error) {
        logDebug('BLE adapter cleanup failed (${error.runtimeType}).');
      }));
    }
    unawaited(_disconnect());
    unawaited(_stateController.close());
  }
}

enum BleStatus {
  disconnected,
  scanning,
  notFound,
  connecting,
  connected,
  dataUpdated,
  adapterOff,
  error,
}

extension BleStatusExt on BleStatus {
  String get message {
    switch (this) {
      case BleStatus.disconnected:
        return 'Disconnected';
      case BleStatus.scanning:
        return 'Scanning...';
      case BleStatus.notFound:
        return 'ESP32 not found';
      case BleStatus.connecting:
        return 'Connecting...';
      case BleStatus.connected:
      case BleStatus.dataUpdated:
        return 'BLE Backup Connected';
      case BleStatus.adapterOff:
        return 'Bluetooth off';
      case BleStatus.error:
        return 'BLE error';
    }
  }
}
