import 'dart:async';
import 'package:flutter/widgets.dart';

/// Serial polling while the app is visible. Pauses work and its timer when the
/// app leaves the foreground; a request after resume always gets a fresh read.
class ForegroundPoller with WidgetsBindingObserver {
  ForegroundPoller({required this.interval, required this.onPoll});
  final Duration interval;
  final Future<void> Function() onPoll;
  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  bool _running = false;
  bool _queued = false;
  bool _foreground = true;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _schedule();
    if (_foreground) unawaited(refresh());
  }

  void _schedule() {
    _timer?.cancel();
    if (!_foreground || _disposed) return;
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  Future<void> refresh({bool queueIfBusy = false}) async {
    if (_disposed || !_foreground) return;
    if (_running) {
      _queued = _queued || queueIfBusy;
      return;
    }
    _running = true;
    try {
      await onPoll();
    } catch (_) {
      // The owner presents connection errors/last readings; retry next interval.
    } finally {
      _running = false;
      if (_queued && !_disposed && _foreground) {
        _queued = false;
        unawaited(refresh());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule();
    if (_foreground) unawaited(refresh(queueIfBusy: true));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
