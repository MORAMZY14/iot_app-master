import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/widgets/room_photo_card.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = FontLoader('RoomTest');
    font.addFont(
      Future.value(
        ByteData.sublistView(
          await File('test/fonts/DejaVuSans.ttf').readAsBytes(),
        ),
      ),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  for (final brightness in Brightness.values) {
    testWidgets('room photo and actions at 320px, $brightness', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = 0;
      var photos = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: 'RoomTest',
            brightness: brightness,
            colorSchemeSeed: const Color(0xFF6C63FF),
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 260,
                child: RoomPhotoCard(
                  room: 'غرفة المعيشة',
                  deviceCount: 4,
                  activeCount: 2,
                  selected: true,
                  icon: Icons.weekend_rounded,
                  onTap: () => selected++,
                  onChangeImage: () => photos++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/images/room_living.png'),
          tester.element(find.byType(RoomPhotoCard)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('غرفة المعيشة'));
      expect(selected, 1);
      await tester.tap(find.byTooltip('Change غرفة المعيشة photo'));
      expect(photos, 1);
      expect(selected, 1);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/room_${brightness.name}.png'),
      );
    });
  }
  testWidgets('large text keeps room actions reachable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 280,
                child: RoomPhotoCard(
                  room: 'A long custom room name',
                  deviceCount: 12,
                  activeCount: 5,
                  selected: false,
                  icon: Icons.bed_rounded,
                  onTap: () {},
                  onChangeImage: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(IconButton), findsOneWidget);
  });
}
