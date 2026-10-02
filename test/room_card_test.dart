import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ui/smart_home_design.dart';
import 'package:iot/widgets/room_card.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('room selection works with real controls in $brightness', (tester) async {
      var selected = 0;
      await tester.pumpWidget(MaterialApp(theme: HomeDesign.theme(brightness), home: Scaffold(body: Center(child: SizedBox(width: 180, height: 220,
        child: RoomCard(room: 'Living Room', deviceCount: 8, activeCount: 3, selected: true, icon: Icons.weekend_outlined, onTap: () => selected++),
      )))));
      expect(find.byType(Image), findsNothing);
      expect(find.text('8 devices'), findsOneWidget);
      expect(find.text('3 on'), findsOneWidget);
      await tester.tap(find.text('Living Room'));
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('large Arabic labels keep the room selector usable', (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(theme: HomeDesign.theme(Brightness.light), home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2)), child: Scaffold(body: Center(child: SizedBox(width: 320, height: 340,
      child: RoomCard(room: 'غرفة المعيشة', deviceCount: 12, activeCount: 5, selected: false, icon: Icons.weekend_outlined, onTap: () => selected++),
    ))))));
    await tester.tap(find.text('غرفة المعيشة'));
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });
}
