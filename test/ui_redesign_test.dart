import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:iot/auth_service.dart' hide userEsp32CodeProvider;
import 'package:iot/ble_service.dart';
import 'package:iot/dashboard_page.dart';
import 'package:iot/login_screen.dart';
import 'package:iot/splash_screen.dart';
import 'package:iot/provisioning_page.dart';
import 'package:iot/wifi_config_page.dart';
import 'package:iot/io_modules_page.dart';
import 'package:iot/ellie/ellie_assistant_sheet.dart';
import 'package:iot/room_image_store.dart';
import 'package:iot/ui/smart_home_design.dart';
import 'package:iot/ui/wifi_credentials_card.dart';

// Fixtures stay in tests. They never run against a user's controller.
class FakeAuth implements AuthService {
  @override
  User? get currentUser => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeBle implements BleService {
  @override
  bool get isConnected => true;
  @override
  BleStatus get currentStatus => BleStatus.connected;
  @override
  Stream<BleStatus> get statusStream => const Stream.empty();
  @override
  Future<void> refreshDevices() async {}
  @override
  Future<Map<String, dynamic>> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 4),
  }) async => {
    'online': true,
    'ssid': 'Home network',
    'ip': '192.168.1.24',
    'gateway': '192.168.1.1',
    'rssi': -45,
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDevices implements ESP32DeviceService {
  final devices = [
    {
      'id': 'lamp',
      'name': 'Floor lamp',
      'room': 'Living Room',
      'state': true,
      'type': 0,
      'channel': 0,
      'moduleId': 'io_1',
    },
    {
      'id': 'fan',
      'name': 'Ceiling fan',
      'room': 'Living Room',
      'state': false,
      'type': 1,
      'channel': 1,
      'moduleId': 'io_1',
    },
    {
      'id': 'bed',
      'name': 'Bedside light',
      'room': 'Bedroom',
      'state': true,
      'type': 0,
      'channel': 2,
      'moduleId': 'io_1',
    },
    {
      'id': 'kit',
      'name': 'Kitchen light',
      'room': 'Kitchen',
      'state': false,
      'type': 0,
      'channel': 3,
      'moduleId': 'io_1',
    },
    {
      'id': 'bath',
      'name': 'Bathroom light',
      'room': 'Bathroom',
      'state': false,
      'type': 0,
      'channel': 4,
      'moduleId': 'io_1',
    },
  ];
  int calls = 0;
  @override
  Future<Map<String, dynamic>> getDevices() async => {'devices': devices};
  @override
  Future<List<String>> getRooms() async => [
    'Living Room',
    'Bedroom',
    'Kitchen',
    'Bathroom',
  ];
  @override
  Future<bool> controlDevice({required String id, required bool state}) async {
    calls++;
    devices.firstWhere((d) => d['id'] == id)['state'] = state;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('UiTest')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            await File('test/fonts/DejaVuSans.ttf').readAsBytes(),
          ),
        ),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    FakeDevices? devices,
    int tab = 0,
    double width = 390,
    double scale = 1,
    bool startup = false,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWith(
            (ref) => startup
                ? Completer<AuthService>().future
                : Future.value(FakeAuth()),
          ),
          bleServiceProvider.overrideWithValue(FakeBle()),
          appNotificationsProvider.overrideWith(
            (ref) => AppNotificationsController()
              ..push(
                key: 'earlier',
                title: 'Welcome home',
                message: 'Your dashboard is ready.',
                icon: Icons.home_outlined,
                color: HomeDesign.blue,
              )
              ..markAllRead()
              ..push(
                key: 'lamp',
                title: 'Living room light turned on',
                message: 'Floor lamp is now on.',
                icon: Icons.lightbulb_outline,
                color: Colors.amber,
              )
              ..push(
                key: 'ble',
                title: 'Bluetooth backup connected',
                message: 'Nearby device control is available.',
                icon: Icons.bluetooth,
                color: HomeDesign.cyan,
              ),
          ),
          esp32DeviceServiceProvider.overrideWith(
            (ref) async => devices ?? FakeDevices(),
          ),
          smartHomeDataProvider.overrideWith(
            (ref) => Stream.value({
              'sensors': {'temperature': 24.2, 'humidity': 48},
              'status': {
                'online': true,
                'ip': '192.168.1.24',
                'rssi': -45,
                'ping': 16,
              },
            }),
          ),
          httpDataProvider.overrideWith(
            (ref) async => {'sensors': {}, 'status': {}},
          ),
          userEsp32CodeProvider.overrideWith((ref) async => 'ESP32-DEMO'),
          selectedNavIndexProvider.overrideWith((ref) => tab),
          roomImageProvider.overrideWith((ref, room) async => null),
        ],
        child: Consumer(
          builder: (context, ref, child) {
            final theme = HomeDesign.theme(
              ref.watch(themeModeProvider) == ThemeMode.light
                  ? Brightness.light
                  : Brightness.dark,
            );
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'UiTest'),
                appBarTheme: theme.appBarTheme.copyWith(
                  titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                    fontFamily: 'UiTest',
                  ),
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: page,
            );
          },
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage(HomeDesign.house),
        tester.element(find.byType(MaterialApp)),
      );
      await precacheImage(
        const AssetImage('assets/images/smart_room_ambient.png'),
        tester.element(find.byType(MaterialApp)),
      );
    });
    await tester.runAsync(() async {
      for (final name in ['living', 'bedroom', 'kitchen', 'bathroom']) {
        await precacheImage(
          AssetImage('assets/images/room_$name.png'),
          tester.element(find.byType(MaterialApp)),
        );
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('login and sign up render and validate at 320px', (tester) async {
    await mount(tester, const LoginScreen(), width: 320);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Sign In').last);
    await tester.tap(find.text('Sign In').last);
    await tester.pump();
    expect(find.textContaining('email', findRichText: true), findsWidgets);
    await unmount(tester);
  });
  testWidgets('home tabs preserve room controls and theme works', (
    tester,
  ) async {
    final devices = FakeDevices();
    await mount(tester, const DashboardPage(), devices: devices);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Light'));
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      Theme.of(tester.element(find.text('Light'))).brightness,
      Brightness.light,
    );
    await tester.tap(find.text('Home').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Living Room').first);
    await tester.tap(find.text('Living Room').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch).last);
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(devices.calls, 1);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
  testWidgets('credentials validate before sending; secure and open networks', (
    tester,
  ) async {
    var calls = 0;
    String? sent;
    await mount(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: WifiCredentialsCard(
            busy: false,
            onSave: (ssid, password) async {
              calls++;
              sent = password;
            },
            buttonLabel: 'Save network',
          ),
        ),
      ),
      width: 320,
      scale: 1.4,
    );
    await tester.tap(find.text('Save network'));
    await tester.pump();
    expect(calls, 0);
    await tester.enterText(find.byType(TextFormField).first, 'Home network');
    await tester.enterText(find.byType(TextFormField).last, '12345678');
    await tester.ensureVisible(find.text('Save network'));
    await tester.tap(find.text('Save network'));
    await tester.pump();
    expect(calls, 1);
    expect(sent, '12345678');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Save network'));
    await tester.pump();
    expect(sent, '');
    expect(calls, 2);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
  final screens = <(String, Widget, int, bool)>[
    ('01-splash', const SplashScreen(), 0, true),
    ('02-login', const LoginScreen(), 0, false),
    ('03-dashboard', const DashboardPage(), 0, false),
    (
      '04-assistant',
      EllieAssistantSheet(
        esp32BaseUri: Uri.parse('http://192.0.2.1'),
        bleService: FakeBle(),
      ),
      0,
      false,
    ),
    ('05-energy', const DashboardPage(), 1, false),
    ('06-alerts', const DashboardPage(), 2, false),
    ('07-settings', const DashboardPage(), 3, false),
    ('08-provision', const ProvisionPage(), 0, false),
    ('09-wifi', const WifiConfigPage(), 0, false),
    (
      '10-modules',
      IoModulesPage(
        loadConfiguration: () async => {
          'i2cBuses': {
            'bus0': {'id': 0, 'sda': 21, 'scl': 22, 'enabled': true},
            'bus1': {'id': 1, 'sda': 4, 'scl': 14, 'enabled': true},
          },
          'ioModules': {
            'io_1': {
              'id': 'io_1',
              'name': 'Living room module',
              'busId': 0,
              'address': 32,
              'enabled': true,
              'ready': true,
            },
            'io_2': {
              'id': 'io_2',
              'name': 'Bedroom module',
              'busId': 1,
              'address': 33,
              'enabled': true,
              'ready': true,
            },
          },
        },
      ),
      0,
      false,
    ),
  ];
  for (final (name, page, tab, startup) in screens) {
    testWidgets('$name actual Flutter screen', (tester) async {
      await mount(tester, page, tab: tab, startup: startup);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/ui/$name.png'),
      );
      if (name == '02-login') {
        await tester.ensureVisible(find.text('Sign Up'));
        await tester.tap(find.text('Sign Up'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Create Account').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/ui/02-signup.png'),
        );
      }
      // Check that controls below the first viewport remain reachable.
      if (name == '03-dashboard') {
        await tester.ensureVisible(find.text('Living Room').first);
        await tester.tap(find.text('Living Room').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Living Room controls'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/ui/03-room-controls.png'),
        );
      }
      if (name == '07-settings') {
        await tester.scrollUntilVisible(
          find.text('I/O modules'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/ui/07-system-settings.png'),
        );
      }
      if (name == '08-provision' || name == '09-wifi') {
        await tester.scrollUntilVisible(
          find.byType(WifiCredentialsCard),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/ui/${name.substring(0, 2)}-network-form.png',
          ),
        );
      }
      if (name == '10-modules') {
        await tester.scrollUntilVisible(find.text('Save & apply changes'), 250);
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/ui/10-module-controls.png'),
        );
      }
      await unmount(tester);
    });
  }
  for (final size in [(320.0, 1.0), (390.0, 1.6), (900.0, 1.0)]) {
    testWidgets('dashboard layout at ${size.$1} with ${size.$2}x text', (
      tester,
    ) async {
      await mount(
        tester,
        const DashboardPage(),
        width: size.$1,
        scale: size.$2,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }
}
