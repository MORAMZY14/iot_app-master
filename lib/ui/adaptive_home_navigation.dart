import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native iOS 26 system tab bar, with a usable Flutter fallback.
class AdaptiveHomeNavigation extends StatefulWidget {
  const AdaptiveHomeNavigation({
    super.key,
    required this.index,
    required this.onChanged,
    this.unreadCount = 0,
  });
  final int index, unreadCount;
  final ValueChanged<int> onChanged;
  @override
  State<AdaptiveHomeNavigation> createState() => _AdaptiveHomeNavigationState();
}

class _AdaptiveHomeNavigationState extends State<AdaptiveHomeNavigation> {
  static const _capabilities = MethodChannel('smarthome/navigation');
  MethodChannel? _viewChannel;
  bool _native = false;
  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) _checkNative();
  }

  Future<void> _checkNative() async {
    try {
      final supported = await _capabilities.invokeMethod<bool>(
        'supportsLiquidGlass',
      );
      if (mounted && supported == true) setState(() => _native = true);
    } on PlatformException {
      // Keep usable fallback controls when the bridge is unavailable.
    } on MissingPluginException {
      // Also supports widget tests and older builds.
    }
  }

  Map<String, Object> get _state => {
    'index': widget.index,
    'unreadCount': widget.unreadCount,
    'dark': Theme.of(context).brightness == Brightness.dark,
    'rtl': Directionality.of(context) == TextDirection.rtl,
  };
  Future<void> _sync() async {
    try {
      await _viewChannel?.invokeMethod<void>('update', _state);
    } on PlatformException {
      if (mounted) setState(() => _native = false);
    } on MissingPluginException {
      if (mounted) setState(() => _native = false);
    }
  }

  @override
  void didUpdateWidget(covariant AdaptiveHomeNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    _viewChannel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_native) {
      return SizedBox(
        height: 76,
        child: UiKitView(
          viewType: 'smarthome/system_tab_bar',
          layoutDirection: Directionality.of(context),
          creationParams: _state,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: (id) {
            if (!mounted) return;
            _viewChannel = MethodChannel('smarthome/system_tab_bar/$id');
            _viewChannel!.setMethodCallHandler((call) async {
              if (mounted && call.method == 'select' && call.arguments is int) {
                final selected = call.arguments as int;
                if (selected >= 0 && selected < 4) widget.onChanged(selected);
              }
            });
            _sync();
          },
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final opaque =
        MediaQuery.highContrastOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 230);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: opaque ? 0 : 20,
            sigmaY: opaque ? 0 : 20,
          ),
          child: Material(
            color: scheme.surface.withValues(alpha: opaque ? 1 : .82),
            shape: StadiumBorder(
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Row(
                children: [
                  for (final (i, item) in const [
                    (Icons.home_rounded, 'Home'),
                    (Icons.bar_chart_rounded, 'Energy'),
                    (Icons.notifications_none_rounded, 'Alerts'),
                    (Icons.settings_outlined, 'Settings'),
                  ].indexed)
                    Expanded(
                      child: Semantics(
                        selected: widget.index == i,
                        button: true,
                        child: AnimatedContainer(
                          duration: duration,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(27),
                            color: widget.index == i
                                ? scheme.primary.withValues(alpha: .16)
                                : Colors.transparent,
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(27),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              widget.onChanged(i);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 9,
                                horizontal: 2,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Badge(
                                    isLabelVisible:
                                        i == 2 && widget.unreadCount > 0,
                                    label: Text(
                                      widget.unreadCount > 99
                                          ? '99+'
                                          : '${widget.unreadCount}',
                                    ),
                                    child: Icon(
                                      item.$1,
                                      size: 24,
                                      color: widget.index == i
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    item.$2,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: widget.index == i
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
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
