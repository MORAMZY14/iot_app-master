import 'ui/wifi_credentials_card.dart';
import 'ui/smart_home_design.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'ble_service.dart';

class ProvisionWifiNetwork {
  final String ssid;
  final int rssi;
  final bool secure;
  final String encryption;

  const ProvisionWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secure,
    required this.encryption,
  });

  factory ProvisionWifiNetwork.fromMap(Map<String, dynamic> map) {
    final enc = (map['encryption'] ?? '').toString();
    final secureValue = map['secure'];
    return ProvisionWifiNetwork(
      ssid: (map['ssid'] ?? '').toString(),
      rssi: map['rssi'] is num ? (map['rssi'] as num).toInt() : -100,
      secure: secureValue is bool ? secureValue : enc.toLowerCase() != 'open',
      encryption: enc.isEmpty ? 'secured' : enc,
    );
  }
}

class ProvisionPage extends ConsumerStatefulWidget {
  const ProvisionPage({super.key});

  @override
  ConsumerState<ProvisionPage> createState() => _ProvisionPageState();
}

class _ProvisionPageState extends ConsumerState<ProvisionPage> {
  final TextEditingController _manualSsidController = TextEditingController();
  StreamSubscription<BleStatus>? _bleSub;

  List<ProvisionWifiNetwork> _networks = const [];
  bool _scanning = false;
  bool _busy = false;
  String? _error;
  String _source = 'Setup AP';
  ProvisionWifiNetwork? _selectedNetwork;

  @override
  void initState() {
    super.initState();
    _bleSub = ref.read(bleServiceProvider).statusStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _manualSsidController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _apGetJson(
    String path, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final response = await http
        .get(
          Uri.parse('${AppConfig.esp32ApBaseUrl}$path'),
          headers: const {'Cache-Control': 'no-cache'},
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ESP32 setup AP returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Invalid ESP32 setup response');
    return decoded.cast<String, dynamic>();
  }

  Future<void> _apPostSave(String ssid, String password) async {
    final response = await http
        .post(
          Uri.parse('${AppConfig.esp32ApBaseUrl}/save'),
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'ssid': ssid, 'pass': password},
        )
        .timeout(AppConfig.longTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'ESP32 setup AP returned HTTP ${response.statusCode}: ${response.body}',
      );
    }
  }

  Future<void> _scanNetworks() async {
    if (_scanning) return;
    HapticFeedback.selectionClick();
    setState(() {
      _scanning = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      List<Map<String, dynamic>> raw;
      if (ble.isConnected) {
        raw = await ble.scanWifi();
        _source = 'Bluetooth';
      } else {
        final data = await _apGetJson('/scan');
        final rawList = data['networks'];
        raw = rawList is List
            ? rawList
                  .whereType<Map>()
                  .map((e) => e.cast<String, dynamic>())
                  .toList()
            : <Map<String, dynamic>>[];
        _source = 'ESP32_Config AP';
      }

      final networks =
          raw
              .map(ProvisionWifiNetwork.fromMap)
              .where((n) => n.ssid.trim().isNotEmpty)
              .toList()
            ..sort((a, b) => b.rssi.compareTo(a.rssi));

      if (!mounted) return;
      setState(() {
        _networks = networks;
        _scanning = false;
        if (networks.isEmpty)
          _error = 'ESP32 scanned successfully, but no networks were found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error =
            'Could not scan from ESP32. Connect your phone to ESP32_Config Wi-Fi, or connect by Bluetooth backup first.\n\n$e';
      });
    }
  }

  Future<void> _saveNetwork(String ssid, String password) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final ok = await ble.connectWifi(ssid, password);
        if (!ok) throw Exception('ESP32 rejected Bluetooth Wi-Fi command');
      } else {
        await _apPostSave(ssid, password);
      }
      if (!mounted) return;
      _showSnack(context, 'Wi-Fi saved. ESP32 is restarting.', _DT.green);
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Failed to save Wi-Fi credentials.\n\n$e';
      });
      _showSnack(context, 'Failed to save Wi-Fi', _DT.red);
    }
  }

  Future<void> _openConnectSheet({ProvisionWifiNetwork? network}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _ProvisionConnectSheet(
        initialSsid: network?.ssid ?? _manualSsidController.text,
        secure: network?.secure ?? true,
        onConnect: (ssid, password) async {
          Navigator.pop(sheetContext);
          await _saveNetwork(ssid, password);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Provision ESP32')),
      body: HomeBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            const HomeHero(
              title: 'Let’s connect your home',
              subtitle: 'Set up your ESP32 with a 2.4 GHz Wi-Fi network.',
              icon: Icons.router_outlined,
              height: 160,
            ),
            const HomeSection('01  CONNECT TO YOUR ESP32'),
            HomeCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Connect your phone to the setup hotspot, or use Bluetooth.',
                    style: TextStyle(height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const HomeGlowIcon(
                      Icons.wifi_tethering_rounded,
                      size: 38,
                    ),
                    title: const Text('ESP32_Config'),
                    subtitle: const Text('Setup hotspot'),
                    trailing: IconButton(
                      tooltip: 'Copy hotspot name',
                      onPressed: () => Clipboard.setData(
                        const ClipboardData(text: 'ESP32_Config'),
                      ),
                      icon: const Icon(Icons.copy_outlined, size: 18),
                    ),
                  ),
                  Row(
                    children: [
                      const Expanded(child: Text('AP password: 12345678')),
                      IconButton(
                        tooltip: 'Copy setup password',
                        onPressed: () => Clipboard.setData(
                          const ClipboardData(text: '12345678'),
                        ),
                        icon: const Icon(Icons.copy_outlined, size: 18),
                      ),
                    ],
                  ),
                  const Divider(),
                  TextButton.icon(
                    onPressed: ble.isConnected
                        ? null
                        : () => unawaited(ble.connect().catchError((_) {})),
                    icon: const Icon(Icons.bluetooth),
                    label: Text(
                      ble.isConnected
                          ? 'Bluetooth connected'
                          : 'Connect Bluetooth (optional)',
                    ),
                  ),
                ],
              ),
            ),
            const HomeSection('02  CHOOSE A NETWORK'),
            HomePrimaryButton(
              label: _scanning ? 'Scanning…' : 'Scan nearby networks',
              icon: Icons.wifi_find_rounded,
              busy: _scanning,
              onPressed: _scanning || _busy ? null : _scanNetworks,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Scan source: $_source',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _InlineError(message: _error!),
              ),
            if (_networks.isEmpty && !_scanning)
              const HomeCard(
                child: Text(
                  'No networks listed yet. Connect to the ESP32 and scan to find your network.',
                ),
              ),
            for (final network in _networks)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: HomeCard(
                  padding: EdgeInsets.zero,
                  glowColor: _selectedNetwork?.ssid == network.ssid
                      ? HomeDesign.blue
                      : null,
                  child: ListTile(
                    enabled: !_busy,
                    onTap: () => setState(() => _selectedNetwork = network),
                    leading: const Icon(Icons.wifi_rounded),
                    title: Text(network.ssid),
                    subtitle: Text(
                      '${network.rssi} dBm • ${network.secure ? 'Secured' : 'Open'}',
                    ),
                    trailing: Icon(
                      _selectedNetwork?.ssid == network.ssid
                          ? Icons.check_circle_rounded
                          : Icons.chevron_right_rounded,
                    ),
                  ),
                ),
              ),
            const HomeSection('03  SAVE & RESTART'),
            WifiCredentialsCard(
              ssid: _selectedNetwork?.ssid ?? '',
              secure: _selectedNetwork?.secure ?? true,
              busy: _busy,
              onSave: _saveNetwork,
              buttonLabel: 'Save & restart ESP32',
            ),
          ],
        ),
      ),
    );
  }
}

class _ProvisionConnectSheet extends StatefulWidget {
  final String initialSsid;
  final bool secure;
  final Future<void> Function(String ssid, String password) onConnect;

  const _ProvisionConnectSheet({
    required this.initialSsid,
    required this.secure,
    required this.onConnect,
  });

  @override
  State<_ProvisionConnectSheet> createState() => _ProvisionConnectSheetState();
}

class _ProvisionConnectSheetState extends State<_ProvisionConnectSheet> {
  late final TextEditingController _ssidController;
  final TextEditingController _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _ssidController = TextEditingController(text: widget.initialSsid);
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: _GCard(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Connect ESP32 to network',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'The ESP32 will save this network and restart.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _ssidController,
                decoration: InputDecoration(
                  labelText: 'SSID',
                  prefixIcon: const Icon(Icons.wifi_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: widget.secure ? 'Password' : 'Password (optional)',
                  prefixIcon: const Icon(Icons.lock_rounded),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _PrimaryButton(
                label: 'Save and restart ESP32',
                icon: Icons.check_rounded,
                onTap: () => widget.onConnect(
                  _ssidController.text.trim(),
                  _passwordController.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  const _InlineError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _DT.red.withValues(alpha: 0.11),
        border: Border.all(color: _DT.red.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: _DT.red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: _DT.red, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool busy;
  final VoidCallback? onTap;
  const _PrimaryButton({
    required this.label,
    required this.icon,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
    onPressed: onTap,
    icon: busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Icon(icon),
    label: Text(label),
    style: ElevatedButton.styleFrom(
      backgroundColor: _DT.purple,
      foregroundColor: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    ),
  );
}

Color _signalColor(int rssi) {
  if (rssi >= -55) return _DT.green;
  if (rssi >= -70) return _DT.amber;
  return _DT.red;
}

IconData _signalIcon(int rssi) {
  if (rssi >= -55) return Icons.signal_wifi_4_bar_rounded;
  if (rssi >= -70) return Icons.network_wifi_3_bar_rounded;
  if (rssi >= -82) return Icons.network_wifi_2_bar_rounded;
  return Icons.network_wifi_1_bar_rounded;
}

void _showSnack(BuildContext context, String msg, Color color) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: color.withValues(alpha: 0.92),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 3),
    ),
  );
}

class _DT {
  static const purple = HomeDesign.blue;
  static const green = Color(0xFF4DFFA0);
  static const amber = Color(0xFFFFB347);
  static const blue = HomeDesign.cyan;
  static const red = Color(0xFFFF5252);
}

class _GCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? glowColor;

  const _GCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.glowColor,
  });

  @override
  Widget build(BuildContext context) =>
      HomeCard(padding: padding, glowColor: glowColor, child: child);
}
