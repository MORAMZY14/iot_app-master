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
    this.imageBytes,
    this.imageAlignment = Alignment.center,
  });
  final String room;
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
    Widget fallback(BuildContext context, Object error, StackTrace? trace) =>
        ColoredBox(
          color: HomeDesign.panel,
          child: Center(child: Icon(icon, size: 38, color: HomeDesign.cyan)),
        );
    return Semantics(
      selected: selected,
      label: '$room, $deviceCount devices, $activeCount on',
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            if (selected)
              BoxShadow(
                color: HomeDesign.blue.withValues(alpha: .26),
                blurRadius: 18,
              ),
          ],
        ),
        child: Material(
          color: HomeDesign.panel,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: selected ? HomeDesign.cyan : HomeDesign.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                imageBytes == null
                    ? Image.asset(
                        defaultPhoto(room),
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        cacheWidth: 768,
                        errorBuilder: fallback,
                      )
                    : Image.memory(
                        imageBytes!,
                        fit: BoxFit.cover,
                        cacheWidth: 768,
                        gaplessPlayback: true,
                        errorBuilder: fallback,
                      ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x55060D19),
                        Color(0x33060D19),
                        Color(0xF5060D19),
                      ],
                      stops: [0, .3, 1],
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Icon(icon, size: 22, color: Colors.white),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: IconButton(
                    tooltip: 'Change $room photo',
                    onPressed: onChangeImage,
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0x66060D19),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 18,
                    ),
                  ),
                ),
                Positioned(
                  left: 13,
                  right: 13,
                  bottom: 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        room,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '$deviceCount ${deviceCount == 1 ? 'device' : 'devices'} · $activeCount on',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFCAD7EA),
                          fontSize: 11,
                        ),
                      ),
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
