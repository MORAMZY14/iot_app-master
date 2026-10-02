import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/network/foreground_poller.dart';

void main() {
  testWidgets('polls serialize and pause in background then refresh on resume', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var calls = 0;
    final first = Completer<void>();
    final poller = ForegroundPoller(interval: const Duration(seconds: 8), onPoll: () async {
      calls++;
      if (calls == 1) await first.future;
    });
    addTearDown(poller.dispose);
    poller.start();
    await tester.pump();
    expect(calls, 1);
    await poller.refresh();
    expect(calls, 1);
    poller.didChangeAppLifecycleState(AppLifecycleState.paused);
    first.complete();
    await tester.pump(const Duration(seconds: 24));
    expect(calls, 1);
    poller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 2);
    poller.dispose();
    await tester.pump(const Duration(seconds: 24));
    expect(calls, 2);
  });
  testWidgets('resume queues one fresh read after an in-flight read', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var calls = 0;
    final pending = Completer<void>();
    final poller = ForegroundPoller(interval: const Duration(seconds: 8), onPoll: () async {
      calls++;
      if (calls == 1) await pending.future;
    });
    addTearDown(poller.dispose);
    poller.start();
    poller.didChangeAppLifecycleState(AppLifecycleState.paused);
    poller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    pending.complete();
    await tester.pump();
    expect(calls, 2);
  });
}
