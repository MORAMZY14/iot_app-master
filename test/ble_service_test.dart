import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ble_service.dart';

class ControllerBle extends BleService {
  ControllerBle() : super(adapterStates: const Stream.empty());

  final commands = <Map<String, dynamic>>[];
  final response = <String, dynamic>{'ok': true};

  @override
  bool get isConnected => true;
  @override
  Future<Map<String, dynamic>> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    commands.add(command);
    return response;
  }
}

class PendingControllerBle extends BleService {
  PendingControllerBle() : super(adapterStates: const Stream.empty());
  final reply = Completer<Map<String, dynamic>>();
  @override
  bool get isConnected => true;
  @override
  Future<Map<String, dynamic>> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 3),
  }) => reply.future;
}

void main() {
  Map<String, dynamic>? decode(String json) => decodeBleCommandResponse(
    utf8.encode(json), requestId: '4_8', expectedCmd: 'status',
    baselineSequence: 7,
  );

  test('an echoed queued command is not accepted as a firmware response', () {
    expect(decode('{"cmd":"status","requestId":"4_8"}'), isNull);
  });

  test('an old or unrelated firmware response cannot acknowledge a command', () {
    expect(decode('{"ok":true,"cmd":"status","requestId":"4_8","responseSequence":7}'), isNull);
    expect(decode('{"ok":true,"cmd":"status","requestId":"4_7","responseSequence":8}'), isNull);
    expect(decode('{"ok":true,"cmd":"get_devices","requestId":"4_8","responseSequence":8}'), isNull);
  });

  test('matching replies and boolean legacy replies retain protocol compatibility', () {
    expect(decode('{"ok":true,"cmd":"status","requestId":"4_8","responseSequence":8,"temp":24}')?['temp'], 24);
    expect(decode('{"ok":true,"cmd":"status","temp":23}')?['temp'], 23);
    expect(decode('{"ok":false,"requestId":"4_8","responseSequence":8,"error":"Unknown command"}')?['ok'], isFalse);
    expect(decode('{"ok":"true","cmd":"status"}'), isNull);
    expect(decode('partial JSON'), isNull);
  });

  test('room control updates all matching device IDs without a room-key collision', () async {
    final service = ControllerBle();
    addTearDown(service.dispose);
    service.devices = [
      {'id': 'lamp', 'room': 'Living Room', 'state': false},
      {'id': 'fan', 'room': 'Living Room', 'state': false},
      {'id': 'bed', 'room': 'Bedroom', 'state': false},
    ];
    service.lights = {'lamp': false, 'fan': false, 'bed': false};
    await service.setLightState('Living Room', true);
    expect(service.lights, {'lamp': true, 'fan': true, 'bed': false});
    expect(service.devices.map((device) => device['state']), [true, true, false]);
    expect(service.commands.single, {'cmd': 'set_room', 'room': 'Living Room', 'state': true});
  });

  test('disconnect discards controller identity and cached sensor/device data', () async {
    final service = BleService(adapterStates: const Stream.empty());
    addTearDown(service.dispose);
    service.controllerIp = '192.168.1.20';
    service.controllerUniqueCode = 'ESP-A';
    service.controllerAssistantName = 'Ellie';
    service.controllerFirmwareVersion = '2.8';
    service.assistantReady = true;
    service.temperature = 26;
    service.humidity = 60;
    service.flameDetected = true;
    service.devices = [{'id': 'lamp', 'state': true}];
    service.lights = {'lamp': true};
    await service.disconnect();
    expect(service.currentStatus, BleStatus.disconnected);
    expect(service.controllerIp, isNull);
    expect(service.controllerUniqueCode, isNull);
    expect(service.controllerAssistantName, isNull);
    expect(service.controllerFirmwareVersion, isNull);
    expect(service.assistantReady, isFalse);
    expect(service.temperature, 0);
    expect(service.humidity, 0);
    expect(service.flameDetected, isFalse);
    expect(service.devices, isEmpty);
    expect(service.lights, isEmpty);
  });

  test('adapter loss clears prior board state before exposing adapter-off status', () async {
    final adapter = StreamController<BluetoothAdapterState>();
    final service = BleService(adapterStates: adapter.stream);
    service.controllerIp = '192.168.1.20';
    adapter.add(BluetoothAdapterState.off);
    await Future<void>.delayed(Duration.zero);
    expect(service.currentStatus, BleStatus.adapterOff);
    expect(service.controllerIp, isNull);
    service.dispose();
    await adapter.close();
  });

  test('a missing IP in a newer BLE status cannot reuse a previous board address', () async {
    final service = ControllerBle();
    addTearDown(service.dispose);
    service.controllerIp = '192.168.1.20';
    service.response.addAll({'ip': '0.0.0.0', 'uniqueCode': 'ESP-A'});
    await service.readControllerStatus();
    expect(service.controllerIp, isNull);
  });

  test('a delayed device response cannot repopulate a disconnected session', () async {
    final service = PendingControllerBle();
    addTearDown(service.dispose);
    final refresh = service.refreshDevices();
    await service.disconnect();
    service.reply.complete({'ok': true, 'devices': [{'id': 'lamp', 'state': true}]});
    await refresh;
    expect(service.devices, isEmpty);
    expect(service.lights, isEmpty);
    expect(service.currentStatus, BleStatus.disconnected);
  });

  test('a delayed room command cannot mark a disconnected session connected', () async {
    final service = PendingControllerBle();
    addTearDown(service.dispose);
    final command = service.setLightState('Living Room', true);
    await service.disconnect();
    service.reply.complete({'ok': true});
    await command;
    expect(service.currentStatus, BleStatus.disconnected);
  });

  test('dispose is idempotent and suppresses future stream events', () async {
    final service = BleService(adapterStates: const Stream.empty());
    final streamDone = service.statusStream.drain<void>();
    service.dispose();
    service.dispose();
    await service.disconnect();
    await streamDone;
    await expectLater(service.sendCommand({'cmd': 'status'}), throwsStateError);
  });
}
