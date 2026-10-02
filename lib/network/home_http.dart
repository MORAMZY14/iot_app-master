import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../app_constants.dart';
import 'local_device_uri.dart';

export 'package:http/http.dart' show Response, ClientException;

class DatabaseSession {
  const DatabaseSession(this.uid, this.token);
  final String uid, token;
}

/// Reuses connections and authenticates only this app's Firebase database.
class HomeHttpClient extends http.BaseClient {
  HomeHttpClient({http.Client? inner, Future<DatabaseSession?> Function()? session})
      : _inner = inner ?? http.Client(), _session = session ?? _currentSession;
  final http.Client _inner;
  final Future<DatabaseSession?> Function() _session;

  static Future<DatabaseSession?> _currentSession() async {
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser;
    if (user == null) return null;
    final token = await user.getIdToken();
    if (token == null || token.isEmpty || auth.currentUser?.uid != user.uid) return null;
    return DatabaseSession(user.uid, token);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final original = request.url;
    var destination = original;
    final database = Uri.parse(AppConfig.databaseUrl);
    final isDatabase = original.scheme == database.scheme &&
        original.host == database.host && original.port == database.port;
    if (original.userInfo.isNotEmpty ||
        (original.scheme == 'http' && !isLocalDeviceUri(original)) ||
        (original.scheme != 'http' && original.scheme != 'https')) {
      throw http.ClientException('Invalid smart-home endpoint');
    }
    if (isDatabase) {
      final session = await _session();
      if (session == null) throw StateError('Please sign in again.');
      final parts = original.pathSegments;
      if (parts.length >= 2 && (parts.first == 'users' || parts.first == 'smartHome')) {
        final uid = parts[1].replaceFirst(RegExp(r'\.json$'), '');
        if (uid != session.uid) throw StateError('The account changed. Please refresh.');
      }
      destination = original.replace(queryParameters: {...original.queryParameters, 'auth': session.token});
    }
    final outgoing = _ForwardRequest(request, destination);
    try {
      final response = await _inner.send(outgoing);
      // Expose the original URL in diagnostics, never an ID-token-bearing URL.
      final safeStream = response.stream.handleError((Object error, StackTrace stack) {
        if (error is http.ClientException) {
          throw http.ClientException('Could not read the smart-home response');
        }
        Error.throwWithStackTrace(error, stack);
      });
      return http.StreamedResponse(safeStream, response.statusCode,
        contentLength: response.contentLength, request: request,
        headers: response.headers, isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection, reasonPhrase: response.reasonPhrase);
    } on http.ClientException {
      throw http.ClientException('Could not reach the smart-home endpoint', original.replace(queryParameters: {...original.queryParameters}..remove('auth')));
    }
  }

  @override
  void close() => _inner.close();
}

class _ForwardRequest extends http.BaseRequest {
  _ForwardRequest(this.source, Uri destination) : super(source.method, destination) {
    headers.addAll(source.headers);
    contentLength = source.contentLength;
    persistentConnection = source.persistentConnection;
    // A redirect must not forward credentials to a different endpoint.
    followRedirects = false;
  }
  final http.BaseRequest source;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return source.finalize();
  }
}

final _client = HomeHttpClient();
Future<http.Response> get(Uri url, {Map<String, String>? headers}) => _client.get(url, headers: headers);
Future<http.Response> post(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) => _client.post(url, headers: headers, body: body, encoding: encoding);
Future<http.Response> put(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) => _client.put(url, headers: headers, body: body, encoding: encoding);
Future<http.Response> patch(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) => _client.patch(url, headers: headers, body: body, encoding: encoding);
Future<http.Response> delete(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) => _client.delete(url, headers: headers, body: body, encoding: encoding);
