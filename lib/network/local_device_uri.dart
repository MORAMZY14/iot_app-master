/// True only for private/link-local IPv4 addresses or local mDNS names.
/// Cloud-supplied controller addresses must never redirect plain HTTP traffic
/// (including Wi-Fi credentials) onto the public internet.
bool isLocalDeviceHost(String host) {
  final name = host.toLowerCase();
  if (name.endsWith('.local') && name.length > 6 && !name.contains('/') && !name.contains('@')) return true;
  final parts = name.split('.');
  if (parts.length != 4) return false;
  final bytes = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
    final byte = int.tryParse(part);
    if (byte == null || byte > 255) return false;
    bytes.add(byte);
  }
  final private = bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254);
  return private && bytes[3] != 0 && bytes[3] != 255;
}

bool isLocalDeviceUri(Uri uri) => uri.scheme == 'http' &&
    uri.userInfo.isEmpty && isLocalDeviceHost(uri.host);
