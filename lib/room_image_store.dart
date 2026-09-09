import 'dart:convert';
import 'dart:typed_data';
import 'room_photo_files_stub.dart'
    if (dart.library.io) 'room_photo_files_io.dart'
    as files;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores user-selected room thumbnails locally on this device.
class RoomImageStore {
  static const String _prefix = 'room_photo_v1_';

  String _key(String room) =>
      '$_prefix${base64Url.encode(utf8.encode(room.trim().toLowerCase()))}';

  Future<Uint8List?> load(String room) async {
    final stored = await files.loadPhoto(_key(room));
    if (stored != null) return stored;
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_key(room));
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final bytes = base64Decode(encoded);
      if (await files.savePhoto(_key(room), bytes))
        await preferences.remove(_key(room));
      return bytes;
    } on FormatException {
      return null;
    }
  }

  Future<void> save(String room, Uint8List bytes) async {
    final preferences = await SharedPreferences.getInstance();
    if (bytes.isEmpty || bytes.lengthInBytes > 2500000) {
      throw const FormatException('Choose a room photo smaller than 2.5 MB.');
    }
    if (await files.savePhoto(_key(room), bytes)) {
      await preferences.remove(_key(room));
    } else {
      await preferences.setString(_key(room), base64Encode(bytes));
    }
  }

  Future<void> remove(String room) async {
    await files.removePhoto(_key(room));
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key(room));
  }

  Future<void> rename(String oldRoom, String newRoom) async {
    if (_key(oldRoom) == _key(newRoom)) return;
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
