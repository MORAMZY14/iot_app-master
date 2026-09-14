import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../ui/smart_home_design.dart';

/// Photo fills the card; a gradient preserves readable room labels.
class RoomPhotoCard extends StatelessWidget {
  const RoomPhotoCard({
    super.key,
    required this.room,
    required this.deviceCount,
    required this.activeCount,
    required this.selected,
    required this.onTap,
    required this.onChangeImage,
    required this.icon,
    this.temperature,
    this.humidity,
    this.imageBytes,
    this.imageAlignment = Alignment.center,
  });
  final String room;
  final double? temperature, humidity;
  final int deviceCount, activeCount;
  final bool selected;
  final VoidCallback onTap, onChangeImage;
  final IconData icon;
  final Uint8List? imageBytes;
  final Alignment imageAlignment;
  static String defaultPhoto(String room) {
    final name = room.toLowerCase();
    if (RegExp(r'bed|نوم').hasMatch(name))
      return 'assets/images/room_bedroom.png';
    if (RegExp(r'kitchen|مطبخ').hasMatch(name))
      return 'assets/images/room_kitchen.png';
    if (RegExp(r'bath|حمام').hasMatch(name))
      return 'assets/images/room_bathroom.png';
    return 'assets/images/room_living.png';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      label: '$room, $deviceCount devices, $activeCount on',
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: selected
              ? [
                  const BoxShadow(color: HomeDesign.blue, blurRadius: 8),
                  BoxShadow(
                    color: HomeDesign.violet.withValues(alpha: .5),
                    blurRadius: 14,
                  ),
                ]
              : [],
        ),
        child: Material(
          color: HomeDesign.panel,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: selected ? const Color(0xFFC0D8FF) : HomeDesign.border,
              width: selected ? 1.3 : 1,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            onLongPress: onChangeImage,
            child: Stack(
              fit: StackFit.expand,
              children: [
                imageBytes == null
                    ? Image.asset(defaultPhoto(room), fit: BoxFit.cover,
                        alignment: imageAlignment, excludeFromSemantics: true)
                    : Image.memory(imageBytes!, fit: BoxFit.cover,
                        alignment: imageAlignment, excludeFromSemantics: true),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x22060B14), Color(0x66060B14), Color(0xF5060B14)],
                      stops: [0, .35, 1],
                    ),
                  ),
                ),
                PositionedDirectional(
                  end: 0, top: 0,
                  child: IconButton(
                    tooltip: 'Change $room photo',
                    onPressed: onChangeImage,
                    icon: const Icon(Icons.photo_camera_outlined,
                        size: 18, color: Colors.white),
                  ),
                ),
                PositionedDirectional(
                  start: 10, end: 10, bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Expanded(child: Text(room, maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14,
                            fontWeight: FontWeight.w600, color: Colors.white))),
                        const Icon(Icons.chevron_right, size: 18, color: Colors.white70),
                      ]),
                      const SizedBox(height: 3),
                      Text('$deviceCount devices · $activeCount on',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: Colors.white70)),
                      const SizedBox(height: 8),
                      RoomClimate(temperature: temperature, humidity: humidity),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The current ESP32 feed is shared across rooms; never imply room-specific data.
class RoomClimate extends StatelessWidget {
  const RoomClimate({super.key, this.temperature, this.humidity});
  final double? temperature, humidity;

  String _reading(double? value, String unit) =>
      value == null || !value.isFinite ? '—' : '${value.toStringAsFixed(unit == '%' ? 0 : 1)}$unit';

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(spacing: 10, runSpacing: 4, children: [
        _metric(Icons.thermostat_rounded, _reading(temperature, '°C'),
            'Temperature', const Color(0xFFFFCC91)),
        _metric(Icons.water_drop_outlined, _reading(humidity, '%'),
            'Humidity', HomeDesign.cyan),
      ]),
      const SizedBox(height: 3),
      const Text('Home sensor', style: TextStyle(fontSize: 9, color: Colors.white70)),
    ],
  );

  Widget _metric(IconData icon, String value, String label, Color color) =>
      Semantics(label: '$label: $value, shared home sensor', excludeSemantics: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text(value, style: const TextStyle(fontSize: 11,
              fontWeight: FontWeight.w600, color: Colors.white)),
        ]));
}
