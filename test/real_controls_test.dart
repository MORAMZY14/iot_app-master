import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ui/adaptive_home_navigation.dart';
import 'package:iot/ui/smart_home_design.dart';

void main() {
  test('runtime controls never use mockup images', () {
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart')) {
        expect(
          file.readAsStringSync(),
          isNot(contains('assets/images/reference_')),
          reason: file.path,
        );
      }
    }
  });
  testWidgets('voice icon is visible and changes to stop on tap', (
    tester,
  ) async {
    var listening = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => HomeVoiceButton(
              listening: listening,
              onPressed: () => setState(() => listening = !listening),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.mic_none)).color,
      Colors.white,
    );
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(listening, isTrue);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
  });
  testWidgets('every navigation tab changes content and exposes unread badge', (
    tester,
  ) async {
    var index = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Text('Page $index'),
            bottomNavigationBar: AdaptiveHomeNavigation(
              index: index,
              unreadCount: 2,
              onChanged: (value) => setState(() => index = value),
            ),
          ),
        ),
      ),
    );
    for (final (i, label) in ['Home', 'Energy', 'Alerts', 'Settings'].indexed) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text('Page $i'), findsOneWidget);
      expect(index, i);
    }
    expect(find.text('2'), findsOneWidget);
  });
  testWidgets(
    'older iOS keeps usable fallback tabs',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('smarthome/navigation'),
        (call) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('smarthome/navigation'),
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: AdaptiveHomeNavigation(
              index: 0,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNothing);
      expect(find.text('Settings'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
