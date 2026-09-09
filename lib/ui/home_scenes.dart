import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'smart_home_design.dart';

/// Scenes are explicit user selections; no device is inferred from a room name.
class HomeScenes extends StatefulWidget {
  const HomeScenes({
    super.key,
    required this.scope,
    required this.devices,
    required this.onToggle,
  });
  final String scope;
  final List<dynamic> devices;
  final Future<void> Function(String, bool) onToggle;
  @override
  State<HomeScenes> createState() => _HomeScenesState();
}

class _HomeScenesState extends State<HomeScenes> {
  Map<String, dynamic> _scenes = {};
  bool _busy = false;
  static const _items = [
    (Icons.home_outlined, 'Home'),
    (Icons.shield_outlined, 'Away'),
    (Icons.bedtime_outlined, 'Sleep'),
    (Icons.movie_outlined, 'Movie'),
  ];
  String get _key => 'home_scenes_v1_${widget.scope}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonDecode(prefs.getString(_key) ?? '{}');
      if (mounted && data is Map)
        setState(() => _scenes = Map<String, dynamic>.from(data));
    } catch (_) {
      /* Corrupt preferences must not run commands. */
    }
  }

  Future<void> _open(String name) async {
    final available = widget.devices
        .whereType<Map>()
        .where((d) => d['id'] != null && d['enabled'] != false)
        .toList();
    final saved = _scenes[name];
    final choices = <String, bool>{
      if (saved is Map)
        for (final d in available)
          if (saved[d['id'].toString()] is bool)
            d['id'].toString(): saved[d['id'].toString()] as bool,
    };
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '$name scene',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Choose which devices to change, then set their desired state. Unselected devices stay as they are.',
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: available.isEmpty
                      ? const Center(
                          child: Text('Add devices to configure this scene.'),
                        )
                      : ListView(
                          children: [
                            for (final d in available)
                              Builder(
                                builder: (context) {
                                  final id = d['id'].toString();
                                  return Row(
                                    children: [
                                      Checkbox(
                                        value: choices.containsKey(id),
                                        onChanged: (v) => update(() {
                                          if (v == true) {
                                            choices[id] = d['state'] == true;
                                          } else {
                                            choices.remove(id);
                                          }
                                        }),
                                      ),
                                      Expanded(
                                        child: Text(
                                          '${d['name'] ?? id}\n${d['room'] ?? ''}',
                                        ),
                                      ),
                                      Switch(
                                        value: choices[id] ?? false,
                                        onChanged: !choices.containsKey(id)
                                            ? null
                                            : (v) =>
                                                  update(() => choices[id] = v),
                                      ),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: choices.isEmpty
                            ? null
                            : () => Navigator.pop(context, 'save'),
                        child: const Text('Save scene'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: choices.isEmpty
                            ? null
                            : () => Navigator.pop(context, 'run'),
                        child: const Text('Save & run'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    setState(() => _busy = true);
    try {
      _scenes[name] = choices;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_scenes));
      if (action == 'run') {
        for (final entry in choices.entries) {
          if (!mounted) break;
          await widget.onToggle(entry.key, entry.value);
        }
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              action == 'run'
                  ? '$name requests sent. Check device states for confirmation.'
                  : '$name scene saved.',
            ),
          ),
        );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not finish the scene. Check device states and connection.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final (i, item) in _items.indexed) ...[
        if (i > 0) const SizedBox(width: 9),
        Expanded(
          child: Semantics(
            button: true,
            label: 'Configure ${item.$2} scene',
            child: InkWell(
              onTap: _busy ? null : () => _open(item.$2),
              borderRadius: BorderRadius.circular(16),
              child: HomeCard(
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 4,
                ),
                child: Column(
                  children: [
                    Icon(
                      item.$1,
                      color: i == 0
                          ? HomeDesign.cyan
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 7),
                    Text(item.$2, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}
