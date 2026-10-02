import 'package:flutter/material.dart';
import '../ui/smart_home_design.dart';

/// A real, accessible room selector; no image decoding or photo permission.
class RoomCard extends StatelessWidget {
  const RoomCard({super.key, required this.room, required this.deviceCount, required this.activeCount, required this.selected, required this.onTap, required this.icon});
  final String room;
  final int deviceCount, activeCount;
  final bool selected;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: '$room, $deviceCount devices, $activeCount on',
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: .1) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: selected ? scheme.primary.withValues(alpha: .5) : scheme.outlineVariant),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                HomeGlowIcon(icon, color: scheme.primary, size: 38),
                const Spacer(),
                if (selected) Icon(Icons.check_circle_rounded, color: scheme.primary, size: 20),
              ]),
              const SizedBox(height: 14),
              Text(room, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('$deviceCount devices', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Text('$activeCount on', style: TextStyle(fontSize: 12, color: activeCount > 0 ? scheme.primary : scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}
