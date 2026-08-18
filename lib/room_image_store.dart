import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores user-selected room thumbnails locally on this device.
class RoomImageStore {
  static const String _prefix = 'room_photo_v1_';

  String _key(String room) =>
      '$_prefix${base64Url.encode(utf8.encode(room.trim().toLowerCase()))}';

  Future<Uint8List?> load(String room) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_key(room));
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(String room, Uint8List bytes) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key(room), base64Encode(bytes));
  }

  Future<void> remove(String room) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key(room));
  }

  Future<void> rename(String oldRoom, String newRoom) async {
    final bytes = await load(oldRoom);
    if (bytes != null) await save(newRoom, bytes);
    await remove(oldRoom);
  }
}

final roomImageStoreProvider = Provider<RoomImageStore>(
  (_) => RoomImageStore(),
);

final roomImageProvider = FutureProvider.family<Uint8List?, String>(
  (ref, room) => ref.watch(roomImageStoreProvider).load(room),
);
