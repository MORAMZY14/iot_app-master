import 'ui/smart_home_design.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

// ============================================================
// 1. Provider for Wi‑Fi scanning & connection
// ============================================================
final wifiSetupProvider =
    StateNotifierProvider<WifiSetupNotifier, WifiSetupState>((ref) {
      return WifiSetupNotifier();
    });

class WifiSetupState {
  final List<WifiNetwork> networks;
  final bool isScanning;
  final bool isConnecting;
  final String? error;

  const WifiSetupState({
    this.networks = const [],
    this.isScanning = false,
    this.isConnecting = false,
    this.error = null,
  });

  WifiSetupState copyWith({
    List<WifiNetwork>? networks,
    bool? isScanning,
    bool? isConnecting,
    String? error,
    bool clearError = false,
  }) {
    return WifiSetupState(
      networks: networks ?? this.networks,
      isScanning: isScanning ?? this.isScanning,
      isConnecting: isConnecting ?? this.isConnecting,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class WifiSetupNotifier extends StateNotifier<WifiSetupState> {
  WifiSetupNotifier() : super(const WifiSetupState());

  Future<bool> _requestPermissions() async {
    final status = await Permission.locationWhenInUse.request();
    if (!mounted) return false;
    if (!status.isGranted) {
      state = state.copyWith(
        error: 'Location permission is required to scan Wi‑Fi networks.',
      );
      return false;
    }
    final isEnabled = await WiFiForIoTPlugin.isEnabled();
    if (!isEnabled) {
      await WiFiForIoTPlugin.setEnabled(true);
    }
    return true;
  }

  Future<void> scanNetworks() async {
    if (!mounted || state.isScanning) return;
    state = state.copyWith(isScanning: true, clearError: true);

    try {
      final hasPermission = await _requestPermissions();
      if (!mounted) return;
      if (!hasPermission) {
        state = state.copyWith(isScanning: false);
        return;
      }
      final list = await WiFiForIoTPlugin.loadWifiList();
      list.sort((a, b) => (b.level ?? -100).compareTo(a.level ?? -100));
      if (mounted) state = state.copyWith(networks: list, isScanning: false);
    } catch (e) {
      if (mounted) state = state.copyWith(isScanning: false, error: 'Could not scan networks. Check Wi-Fi and permissions.');
    }
  }

  Future<void> connectToNetwork(
    String ssid,
    String password,
    BuildContext context,
  ) async {
    if (ssid.isEmpty) {
      _showSnack(context, 'SSID cannot be empty', _DT.red);
      return;
    }
    if (password.isEmpty) {
      _showSnack(context, 'Please enter the Wi‑Fi password', _DT.red);
      return;
    }
    if (!mounted || state.isConnecting) return;

    state = state.copyWith(isConnecting: true, clearError: true);
    try {
      final success = await WiFiForIoTPlugin.connect(
        ssid,
        password: password,
        security: NetworkSecurity.WPA,
        joinOnce: true,
      ).timeout(const Duration(seconds: 15));
      if (success) {
        _showSnack(context, 'Connected to $ssid', _DT.green);
        if (context.mounted) Navigator.pop(context);
      } else {
        throw Exception('Connection failed');
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(error: 'Could not connect. Check the Wi-Fi password.');
        _showSnack(context, state.error!, _DT.red);
      }
    } finally {
      if (mounted) state = state.copyWith(isConnecting: false);
    }
  }
}

// ============================================================
// 2. Design tokens and widgets
// ============================================================
class _DT {
  static const purple = Color(0xFF6C63FF);
  static const green = Color(0xFF4DFFA0);
  static const amber = Color(0xFFFFB347);
  static const blue = Color(0xFF64B5F6);
  static const red = Color(0xFFFF5252);
  static const espConnected = Color(0xFF4DFFA0);
}

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
  Widget build(BuildContext context) => HomeCard(padding: padding, glowColor: dangerBorder ? _DT.red : glowColor, child: child);
}

class _WallpaperBackground extends StatelessWidget {
  const _WallpaperBackground({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => HomeBackground(child: child);
}

void _showSnack(BuildContext context, String msg, Color color) {
  if (!context.mounted) return;
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

class _GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final IconData actionIcon;
  final VoidCallback? onAction;

  const _GlassAppBar({
    required this.title,
    required this.actionIcon,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => AppBar(title: Text(title), actions: [IconButton(icon: Icon(actionIcon), onPressed: onAction, tooltip: 'Scan networks')]);
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class WifiSetupPage extends ConsumerStatefulWidget {
  const WifiSetupPage({super.key});

  @override
  ConsumerState<WifiSetupPage> createState() => _WifiSetupPageState();
}

class _WifiSetupPageState extends ConsumerState<WifiSetupPage> {
  final TextEditingController _passwordController = TextEditingController();
  String? _selectedSsid;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(wifiSetupProvider.notifier).scanNetworks());
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wifiSetupProvider);
    final notifier = ref.read(wifiSetupProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _GlassAppBar(
        title: 'Wi‑Fi Setup',
        actionIcon: Icons.refresh,
        onAction: state.isScanning ? null : () => notifier.scanNetworks(),
      ),
      body: _WallpaperBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _GCard(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Wi‑Fi Password',
                    prefixIcon: Icon(Icons.lock),
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  enabled: !state.isConnecting,
                ),
              ),
              const SizedBox(height: 16),
              _GCard(
                padding: const EdgeInsets.all(16),
                child: _buildNetworkList(state, notifier),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkList(WifiSetupState state, WifiSetupNotifier notifier) {
    if (state.isScanning) {
      return const Center(child: CircularProgressIndicator(color: _DT.purple));
    }
    if (state.error != null && state.networks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off,
              size: 64,
              color: _DT.red.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(state.error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            _PillBtn(label: 'Retry', onTap: () => notifier.scanNetworks()),
          ],
        ),
      );
    }
    if (state.networks.isEmpty) {
      return const Center(
        child: Text('No Wi‑Fi networks found. Pull down to refresh.'),
      );
    }

    return RefreshIndicator(
      onRefresh: () => notifier.scanNetworks(),
      child: ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: state.networks.length,
        itemBuilder: (context, index) {
          final wifi = state.networks[index];
          final ssid = wifi.ssid ?? 'Unknown';
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _GCard(
              padding: const EdgeInsets.all(12),
              child: ListTile(
                leading: Icon(
                  _signalIcon(wifi.level ?? -100),
                  color: _DT.purple,
                ),
                title: Text(
                  ssid,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: _selectedSsid == ssid && state.isConnecting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _DT.purple,
                        ),
                      )
                    : Icon(
                        Icons.chevron_right_rounded,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.3),
                      ),
                onTap: state.isConnecting
                    ? null
                    : () {
                        setState(() => _selectedSsid = ssid);
                        notifier.connectToNetwork(
                          ssid,
                          _passwordController.text,
                          context,
                        );
                      },
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _signalIcon(int level) {
    if (level >= -50) return Icons.signal_wifi_4_bar;
    if (level >= -60) return Icons.signal_wifi_0_bar;
    if (level >= -70) return Icons.signal_wifi_0_bar;
    if (level >= -80) return Icons.signal_wifi_0_bar;
    return Icons.signal_wifi_0_bar;
  }
}

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
