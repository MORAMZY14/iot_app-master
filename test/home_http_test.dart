import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iot/app_constants.dart';
import 'package:iot/network/home_http.dart';
import 'package:iot/network/local_device_uri.dart';

class _BodyErrorClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream<List<int>>.error(
        http.ClientException('Body failed', request.url)), 200);
}

void main() {
  test('only private or local controller destinations allow plain HTTP', () {
    for (final host in ['192.168.4.1', '10.0.0.2', '172.16.1.3', '169.254.1.2', 'esp32.local']) {
      expect(isLocalDeviceUri(Uri.parse('http://$host/api/devices')), isTrue);
    }
    for (final host in ['8.8.8.8', '172.15.1.2', '172.32.1.2', '127.0.0.1', '192.168.1.999', 'example.com', '192.168.1.255']) {
      expect(isLocalDeviceHost(host), isFalse);
    }
  });
  test('database gets token; local requests never receive it', () async {
    final requests = <http.Request>[];
    final client = HomeHttpClient(
      session: () async => const DatabaseSession('alice', 'private-token'),
      inner: MockClient((request) async { requests.add(request); return http.Response('{}', 200); }),
    );
    addTearDown(client.close);
    final response = await client.get(Uri.parse('${AppConfig.databaseUrl}/smartHome/alice.json'));
    expect(requests.first.url.queryParameters['auth'], 'private-token');
    expect(response.request!.url.queryParameters.containsKey('auth'), isFalse);
    await client.post(Uri.parse('http://192.168.4.1/api/wifi'), body: 'password');
    expect(requests.last.url.queryParameters.containsKey('auth'), isFalse);
    expect(requests.last.followRedirects, isFalse);
  });
  test('response-body failures cannot expose the database token', () async {
    final client = HomeHttpClient(inner: _BodyErrorClient(),
      session: () async => const DatabaseSession('alice', 'private-token'));
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('${AppConfig.databaseUrl}/smartHome/alice.json')),
      throwsA(isA<http.ClientException>()
        .having((error) => error.toString(), 'token', isNot(contains('private-token')))
        .having((error) => error.toString(), 'query', isNot(contains('auth=')))));
  });
  test('old-account request fails before it reaches the database', () async {
    var sent = false;
    final client = HomeHttpClient(
      session: () async => const DatabaseSession('bob', 'token'),
      inner: MockClient((_) async { sent = true; return http.Response('{}', 200); }),
    );
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('${AppConfig.databaseUrl}/users/alice.json')), throwsStateError);
    expect(sent, isFalse);
  });
  test('unauthenticated database requests and public HTTP are blocked', () async {
    final client = HomeHttpClient(session: () async => null,
      inner: MockClient((_) async => http.Response('{}', 200)));
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('${AppConfig.databaseUrl}/users/alice.json')), throwsStateError);
    await expectLater(client.post(Uri.parse('http://example.com/api/wifi'), body: 'secret'), throwsA(isA<http.ClientException>()));
  });
}
