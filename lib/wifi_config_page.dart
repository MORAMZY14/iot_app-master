import 'ui/wifi_credentials_card.dart';
import 'ui/smart_home_design.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'ble_service.dart';

class EspWifiNetwork {
  final String ssid;
  final int rssi;
  final int? channel;
  final String encryption;
  final bool secure;
  final bool current;

  const EspWifiNetwork({
    required this.ssid,
    required this.rssi,
    this.channel,
    required this.encryption,
    required this.secure,
    required this.current,
  });

  factory EspWifiNetwork.fromMap(Map<String, dynamic> map) {
    final enc = (map['encryption'] ?? '').toString();
    final secureValue = map['secure'];
    return EspWifiNetwork(
      ssid: (map['ssid'] ?? '').toString(),
      rssi: (map['rssi'] is num) ? (map['rssi'] as num).toInt() : -100,
      channel: map['channel'] is num ? (map['channel'] as num).toInt() : null,
      encryption: enc.isEmpty ? 'secured' : enc,
      secure: secureValue is bool ? secureValue : enc.toLowerCase() != 'open',
      current: map['current'] == true,
    );
  }
}

class EspWifiStatus {
  final bool online;
  final String ssid;
  final String ip;
  final String gateway;
  final int rssi;
  final String uniqueCode;
  final String source;

  const EspWifiStatus({
    required this.online,
    required this.ssid,
    required this.ip,
    required this.gateway,
    required this.rssi,
    required this.uniqueCode,
    required this.source,
  });

  factory EspWifiStatus.fromMap(Map<String, dynamic> map, String source) {
    return EspWifiStatus(
      online:
          map['online'] == true ||
          map['wifiConnected'] == true ||
          (map['ip'] ?? '').toString().isNotEmpty,
      ssid: (map['ssid'] ?? '').toString(),
      ip: (map['ip'] ?? '').toString(),
      gateway: (map['gateway'] ?? '').toString(),
      rssi: map['rssi'] is num ? (map['rssi'] as num).toInt() : 0,
      uniqueCode: (map['uniqueCode'] ?? '').toString(),
      source: source,
    );
  }
}

class WifiConfigPage extends ConsumerStatefulWidget {
  const WifiConfigPage({super.key});

  @override
  ConsumerState<WifiConfigPage> createState() => _WifiConfigPageState();
}

class _WifiConfigPageState extends ConsumerState<WifiConfigPage> {
  EspWifiNetwork? _selectedNetwork;
  final TextEditingController _manualSsidController = TextEditingController();
  StreamSubscription<BleStatus>? _bleSub;

  EspWifiStatus? _status;
  List<EspWifiNetwork> _networks = const [];
  bool _loadingStatus = true;
  bool _scanning = false;
  bool _busy = false;
  String? _error;
  String? _lastIp;

  @override
  void initState() {
    super.initState();
    _bleSub = ref.read(bleServiceProvider).statusStream.listen((_) {
      if (mounted) setState(() {});
    });
    Future.microtask(_loadStatus);
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _manualSsidController.dispose();
    super.dispose();
  }

  bool get _bleReady => ref.read(bleServiceProvider).isConnected;

  Future<String?> _lookupEspIp() async {
    if (_lastIp != null && _lastIp!.isNotEmpty) return _lastIp;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final codeResponse = await http
        .get(
          Uri.parse(
            '${AppConfig.databaseUrl}/users/${user.uid}/esp32Code.json',
          ),
        )
        .timeout(AppConfig.mediumTimeout);
    if (codeResponse.statusCode != 200 || codeResponse.body == 'null')
      return null;
    final code = (jsonDecode(codeResponse.body) ?? '').toString();
    if (code.isEmpty) return null;

    final statusResponse = await http
        .get(Uri.parse('${AppConfig.databaseUrl}/esp_public/$code/status.json'))
        .timeout(AppConfig.mediumTimeout);
    if (statusResponse.statusCode != 200 || statusResponse.body == 'null')
      return null;
    final decoded = jsonDecode(statusResponse.body);
    if (decoded is Map && decoded['ip'] != null) {
      _lastIp = decoded['ip'].toString();
      return _lastIp;
    }
    return null;
  }

  Future<Map<String, dynamic>> _localGetJson(
    String path, {
    Duration? timeout,
  }) async {
    final ip = await _lookupEspIp();
    if (ip == null || ip.isEmpty) {
      throw Exception(
        'ESP32 IP is unavailable. Connect Bluetooth backup or make sure the phone has internet to read the ESP status.',
      );
    }
    final response = await http
        .get(
          Uri.parse('http://$ip$path'),
          headers: const {'Cache-Control': 'no-cache'},
        )
        .timeout(timeout ?? AppConfig.longTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ESP32 returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Invalid ESP32 response');
    return decoded.cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> _localPostJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final ip = await _lookupEspIp();
    if (ip == null || ip.isEmpty) {
      throw Exception(
        'ESP32 IP is unavailable. Use Bluetooth backup or connect to the same Wi-Fi as the ESP32.',
      );
    }
    final response = await http
        .post(
          Uri.parse('http://$ip$path'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(AppConfig.longTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'ESP32 returned HTTP ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = response.body.trim().isEmpty
        ? <String, dynamic>{'success': true}
        : jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Invalid ESP32 response');
    return decoded.cast<String, dynamic>();
  }

  Future<void> _loadStatus() async {
    if (!mounted) return;
    setState(() {
      _loadingStatus = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final data = await ble.sendCommand({
          'cmd': 'wifi_status',
        }, timeout: const Duration(seconds: 4));
        if (!mounted) return;
        setState(() {
          _status = EspWifiStatus.fromMap(data, 'Bluetooth');
          _loadingStatus = false;
        });
        return;
      }

      final data = await _localGetJson(
        '/api/wifi/status',
        timeout: AppConfig.mediumTimeout,
      );
      if (!mounted) return;
      setState(() {
        _status = EspWifiStatus.fromMap(data, 'Local Wi-Fi');
        _loadingStatus = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingStatus = false;
        _error =
            'Could not read ESP32 Wi-Fi status. Connect Bluetooth backup, or make sure your phone can reach the ESP32 local IP.\n\n$e';
      });
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
      String source;
      if (ble.isConnected) {
        raw = await ble.scanWifi();
        source = 'Bluetooth';
        await _loadStatus();
      } else {
        final data = await _localGetJson(
          '/api/wifi/scan',
          timeout: const Duration(seconds: 18),
        );
        final rawList = data['networks'];
        raw = rawList is List
            ? rawList
                  .whereType<Map>()
                  .map((e) => e.cast<String, dynamic>())
                  .toList()
            : <Map<String, dynamic>>[];
        source = 'Local Wi-Fi';
        if (data['connected'] is Map) {
          _status = EspWifiStatus.fromMap(
            (data['connected'] as Map).cast<String, dynamic>(),
            source,
          );
        }
      }

      final networks =
          raw
              .map(EspWifiNetwork.fromMap)
              .where((n) => n.ssid.trim().isNotEmpty)
              .toList()
            ..sort((a, b) => b.rssi.compareTo(a.rssi));

      if (!mounted) return;
      setState(() {
        _networks = networks;
        _scanning = false;
        if (networks.isEmpty) {
          _error =
              'ESP32 scan completed, but no nearby networks were returned. Try again closer to the router.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error =
            'ESP32 Wi-Fi scan failed. Use Bluetooth backup if the phone is not on the same network as the ESP32.\n\n$e';
      });
    }
  }

  Future<void> _connectToNetwork(String ssid, String password) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final ok = await ble.connectWifi(ssid, password);
        if (!ok) throw Exception('ESP32 rejected the Bluetooth Wi-Fi command');
      } else {
        await _localPostJson('/api/wifi/connect', {
          'ssid': ssid,
          'password': password,
          'pass': password,
        });
      }
      if (!mounted) return;
      _showSnack(
        context,
        'Wi-Fi saved. ESP32 will restart and reconnect.',
        _DT.green,
      );
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Failed to save Wi-Fi credentials.\n\n$e';
      });
      _showSnack(context, 'Wi-Fi change failed', _DT.red);
    }
  }

  Future<void> _forgetNetwork() async {
    final confirm = await _showConfirmDialog(
      context,
      title: 'Forget ESP32 Wi-Fi?',
      message:
          'The ESP32 will clear saved Wi-Fi credentials and restart into setup mode.',
      confirmText: 'Forget',
      danger: true,
    );
    if (confirm != true || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final ok = await ble.forgetWifi();
        if (!ok) throw Exception('ESP32 rejected the Bluetooth forget command');
      } else {
        await _localPostJson('/api/wifi/forget', <String, dynamic>{});
      }
      if (!mounted) return;
      _showSnack(
        context,
        'Wi-Fi forgotten. ESP32 is restarting into setup mode.',
        _DT.amber,
      );
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            'Forget network failed. Connect Bluetooth backup or use the ESP32_Config setup mode.\n\n$e';
      });
    }
  }

  Future<void> _openConnectSheet({EspWifiNetwork? network}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _WifiConnectSheet(
        initialSsid: network?.ssid ?? _manualSsidController.text,
        secure: network?.secure ?? true,
        busy: _busy,
        onConnect: (ssid, password) async {
          Navigator.pop(sheetContext);
          await _connectToNetwork(ssid, password);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleServiceProvider);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text(''),
        actions: [
          IconButton(
            tooltip: 'Refresh network status',
            onPressed: _loadingStatus ? null : _loadStatus,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: HomeBackground(
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadStatus();
            await _scanNetworks();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
            children: [
              const HomeHero(
                title: 'ESP32 Wi-Fi Manager',
                subtitle: 'Connect ESP32 to Wi-Fi',
                icon: Icons.memory_rounded,
                height: 76,
                photograph: false,
                showTop: false,
              ),

              _CurrentNetworkCard(
                status: _status,
                loading: _loadingStatus,
                bleConnected: ble.isConnected,
                busy: _busy,
                onForget: _forgetNetwork,
                onConnectBle: () => unawaited(ble.connect().catchError((_) {})),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nearby networks from ESP32',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          'Networks found by ESP32 (last scan)',
                          style: TextStyle(
                            fontSize: 9,
                            color: Color(0xFFA6BBDD),
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _scanning ? null : _scanNetworks,
                    icon: const Icon(Icons.wifi, size: 15),
                    label: Text(
                      _scanning ? '…' : 'Scan',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh network status',
                    onPressed: _loadingStatus ? null : _loadStatus,
                    icon: const Icon(Icons.refresh, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _InlineError(message: _error!),
                ),
              if (_networks.isEmpty && !_scanning)
                const HomeCard(
                  child: Text(
                    'No networks found yet. Scan using the ESP32’s antenna.',
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
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      enabled: !_busy,
                      onTap: () => setState(() => _selectedNetwork = network),
                      leading: const Icon(Icons.wifi_rounded),
                      title: Text(
                        network.ssid,
                        style: const TextStyle(fontSize: 12),
                      ),
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
              const HomeSection('Manual Wi-Fi Configuration'),
              WifiCredentialsCard(
                ssid: _selectedNetwork?.ssid ?? '',
                secure: _selectedNetwork?.secure ?? true,
                busy: _busy,
                onSave: _connectToNetwork,
                buttonLabel: 'Save and reconnect ESP32',
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: _busy ? null : _forgetNetwork,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Forget Wi-Fi'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WifiConnectSheet extends StatefulWidget {
  final String initialSsid;
  final bool secure;
  final bool busy;
  final Future<void> Function(String ssid, String password) onConnect;

  const _WifiConnectSheet({
    required this.initialSsid,
    required this.secure,
    required this.busy,
    required this.onConnect,
  });

  @override
  State<_WifiConnectSheet> createState() => _WifiConnectSheetState();
}

class _WifiConnectSheetState extends State<_WifiConnectSheet> {
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
                'Connect ESP32 to Wi-Fi',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'Enter the password for this network. The ESP32 will restart after saving.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _ssidController,
                textInputAction: TextInputAction.next,
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
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => widget.onConnect(
                  _ssidController.text.trim(),
                  _passwordController.text,
                ),
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
                label: 'Save and reconnect ESP32',
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

class _CurrentNetworkCard extends StatelessWidget {
  final EspWifiStatus? status;
  final bool loading;
  final bool bleConnected;
  final bool busy;
  final VoidCallback onForget;
  final VoidCallback onConnectBle;

  const _CurrentNetworkCard({
    required this.status,
    required this.loading,
    required this.bleConnected,
    required this.busy,
    required this.onForget,
    required this.onConnectBle,
  });

  @override
  Widget build(BuildContext context) {
    final connected = status?.online == true;
    return HomeCard(
      child: Column(
        children: [
          Row(
            children: [
              const HomeGlowIcon(Icons.wifi, color: HomeDesign.cyan, size: 47),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Connected Network',
                      style: TextStyle(fontSize: 11, color: Color(0xFFA6BBDD)),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      status?.ssid.isNotEmpty == true
                          ? status!.ssid
                          : 'No network',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      loading
                          ? 'Reading status…'
                          : connected
                          ? '● ESP32 is connected'
                          : 'ESP32 Wi-Fi unavailable',
                      style: TextStyle(
                        fontSize: 10,
                        color: connected
                            ? HomeDesign.cyan
                            : Colors.orangeAccent,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 70,
                child: TextButton(
                  onPressed: bleConnected ? null : onConnectBle,
                  child: Text(
                    bleConnected ? 'Bluetooth ready' : 'Connect BLE',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final (i, v) in [
                (Icons.location_on_outlined, 'IP Address', status?.ip ?? '—'),
                (Icons.router_outlined, 'Gateway', status?.gateway ?? '—'),
                (
                  Icons.signal_cellular_alt,
                  'RSSI',
                  status == null ? '—' : '${status!.rssi} dBm',
                ),
              ].indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: HomeCard(
                    padding: const EdgeInsets.all(7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(v.$1, size: 18, color: HomeDesign.blue),
                        const SizedBox(height: 4),
                        Text(
                          v.$2,
                          style: const TextStyle(
                            fontSize: 8,
                            color: Color(0xFFA6BBDD),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(v.$3, style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
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

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.65),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      color: color.withValues(alpha: 0.14),
      border: Border.all(color: color.withValues(alpha: 0.28)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w800),
    ),
  );
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

class _SecondaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const _SecondaryButton({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: _DT.blue,
      side: BorderSide(color: _DT.blue.withValues(alpha: 0.4)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
    ),
  );
}

class _DangerButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const _DangerButton({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: _DT.red,
      side: BorderSide(color: _DT.red.withValues(alpha: 0.4)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
    ),
  );
}

Future<bool?> _showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmText,
  bool danger = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: danger ? _DT.red : _DT.purple,
            foregroundColor: Colors.white,
          ),
          child: Text(confirmText),
        ),
      ],
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
