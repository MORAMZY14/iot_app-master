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
    return Semantics(
      selected: selected,
      label: '$room, $deviceCount devices, $activeCount on',
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
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
            borderRadius: BorderRadius.circular(11),
            side: BorderSide(
              color: selected ? const Color(0xFFC0D8FF) : HomeDesign.border,
              width: selected ? 1.3 : 1,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            onLongPress: onChangeImage,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      imageBytes == null
                          ? ReferenceArt.room(room)
                          : Image.memory(imageBytes!, fit: BoxFit.cover),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: SizedBox(
                          width: 30,
                          height: 28,
                          child: IconButton(
                            tooltip: 'Change $room photo',
                            padding: EdgeInsets.zero,
                            onPressed: onChangeImage,
                            icon: const Icon(
                              Icons.photo_camera_outlined,
                              size: 13,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(9, 5, 7, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              room,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '$deviceCount devices  |  ● $activeCount active',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 8.5,
                                color: Color(0xFFAFBED8),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: Colors.white,
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
