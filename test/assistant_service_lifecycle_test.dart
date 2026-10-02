import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iot/ble_service.dart';
import 'package:iot/ellie/ellie_voice_controller.dart';
import 'package:iot/ellie/local_llm_service.dart';
import 'package:iot/ellie/ellie_language.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

class _SpeechFake extends Fake implements SpeechToText {
  final initialization = Completer<bool>();
  int initializationCalls = 0;
  int localeCalls = 0;
  int listenCalls = 0;
  bool nativeInitialized = false;
  bool listening = false;
  bool failCancel = false;

  @override
  SpeechStatusListener? statusListener;
  @override
  SpeechErrorListener? errorListener;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #initialize:
        initializationCalls++;
        if (nativeInitialized) return Future<bool>.value(true);
        statusListener = invocation.namedArguments[#onStatus]
            as SpeechStatusListener?;
        errorListener = invocation.namedArguments[#onError]
            as SpeechErrorListener?;
        return initialization.future.then((ready) {
          nativeInitialized = ready;
          return ready;
        });
      case #isListening:
        return listening;
      case #locales:
        localeCalls++;
        return Future<List<LocaleName>>.value(<LocaleName>[]);
      case #systemLocale:
        return Future<LocaleName?>.value(null);
      case #listen:
        listenCalls++;
        listening = true;
        return Future<void>.value();
      case #stop:
        listening = false;
        return Future<void>.value();
      case #cancel:
        listening = false;
        return failCancel
            ? Future<void>.error(StateError('Native cancellation failed'))
            : Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _TtsFake extends Fake implements FlutterTts {
  int languageCalls = 0;
  int stopCalls = 0;
  bool failStop = false;
  final speakStarted = Completer<void>();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #getLanguages:
        languageCalls++;
        return Future<List<String>>.value(<String>['en-US']);
      case #stop:
        stopCalls++;
        return failStop
            ? Future<dynamic>.error(StateError('Native TTS stop failed'))
            : Future<dynamic>.value(1);
      case #awaitSpeakCompletion:
      case #setSpeechRate:
      case #setPitch:
      case #setVolume:
      case #setLanguage:
        return Future<dynamic>.value(1);
      case #isLanguageAvailable:
        return Future<dynamic>.value(true);
      case #speak:
        if (!speakStarted.isCompleted) speakStarted.complete();
        return Completer<dynamic>().future;
    }
    return super.noSuchMethod(invocation);
  }
}

class _TrackingClient extends http.BaseClient {
  final _delegate = MockClient((request) async => http.Response('{}', 200));
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _delegate.send(request);

  @override
  void close() {
    closed = true;
    _delegate.close();
  }
}

class _BleFake extends Fake implements BleService {
  int intentCalls = 0;

  @override
  bool get isConnected => true;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #setAssistantName:
        return Future<bool>.value(true);
      case #sendEllieText:
        intentCalls++;
        return Future<Map<String, dynamic>>.value(<String, dynamic>{
          'handled': true,
          'speakerQueued': true,
          'reply': 'Desk Lamp is on.',
        });
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  EllieVoiceController controller(_SpeechFake speech, _TtsFake tts,
      {http.Client? client, Uri? uri, BleService? ble}) =>
      EllieVoiceController(
        esp32BaseUri: uri ?? Uri.parse('http://192.168.4.1'),
        outputMode: EllieOutputMode.esp32,
        speechToText: speech,
        flutterTts: tts,
        httpClient: client ?? _TrackingClient(),
        bleService: ble,
      );

  test('concurrent voice initialization shares one pending operation', () async {
    final speech = _SpeechFake();
    final c = controller(speech, _TtsFake());
    final first = c.initialize();
    final second = c.initialize();
    expect(identical(first, second), isTrue);
    expect(speech.initializationCalls, 1);
    speech.initialization.complete(false);
    expect(await first, isFalse);
    expect(await second, isFalse);
    await c.dispose();
  });

  test('closing during voice initialization prevents late microphone work', () async {
    final speech = _SpeechFake();
    final tts = _TtsFake();
    final c = controller(speech, tts);
    final listening = c.startListening();
    await c.dispose();
    speech.initialization.complete(true);
    await listening;
    expect(speech.localeCalls, 0);
    expect(speech.listenCalls, 0);
    expect(tts.languageCalls, 0);
    expect(await c.initialize(), isFalse);
  });

  test('rapid microphone taps start one native listening session', () async {
    final speech = _SpeechFake();
    final c = controller(speech, _TtsFake());
    final first = c.startListening();
    final second = c.startListening();
    speech.initialization.complete(true);
    await Future.wait<void>(<Future<void>>[first, second]);
    expect(speech.initializationCalls, 1);
    expect(speech.listenCalls, 1);
    await c.dispose();
  });

  test('reopening rebinds callbacks retained by the recognizer plugin', () async {
    final speech = _SpeechFake();
    speech.initialization.complete(true);
    final first = controller(speech, _TtsFake());
    await first.initialize();
    await first.dispose();
    final reopened = controller(speech, _TtsFake());
    final events = <EllieVoiceEvent>[];
    final subscription = reopened.events.listen(events.add);
    await reopened.initialize();
    speech.errorListener!(SpeechRecognitionError('offline_unavailable', true));
    await Future<void>.delayed(Duration.zero);
    expect(events.any((event) => event.phase == EllieVoicePhase.error), isTrue);
    await subscription.cancel();
    await reopened.dispose();
  });

  test('native cleanup errors still close HTTP and the event stream', () async {
    final speech = _SpeechFake()..failCancel = true;
    final tts = _TtsFake()..failStop = true;
    final client = _TrackingClient();
    final c = controller(speech, tts, client: client);
    final closed = Completer<void>();
    c.events.listen((_) {}, onDone: closed.complete);
    await c.dispose();
    await closed.future;
    expect(client.closed, isTrue);
    expect(tts.stopCalls, 1);
  });

  testWidgets('a timed-out phone utterance is stopped before returning idle', (tester) async {
    final speech = _SpeechFake();
    speech.initialization.complete(false);
    final tts = _TtsFake();
    final c = EllieVoiceController(
      esp32BaseUri: Uri.parse('http://unconfigured.invalid'),
      outputMode: EllieOutputMode.phone,
      speechToText: speech,
      flutterTts: tts,
      httpClient: _TrackingClient(),
    );
    final events = <EllieVoiceEvent>[];
    final subscription = c.events.listen(events.add);
    final speaking = c.testPhoneVoice();
    await tester.pump();
    expect(tts.speakStarted.isCompleted, isTrue);
    await tester.pump(const Duration(seconds: 40));
    await speaking;
    expect(tts.stopCalls, greaterThanOrEqualTo(2));
    expect(events.last.phase, EllieVoicePhase.idle);
    expect(events.last.warning, isNotNull);
    await subscription.cancel();
    await c.dispose();
  });

  test('an unknown or public board address never receives assistant HTTP', () async {
    for (final address in <String>[
      'http://unconfigured.invalid',
      'http://8.8.8.8',
      'http://example.com',
    ]) {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      });
      final speech = _SpeechFake();
      speech.initialization.complete(false);
      final c = controller(speech, _TtsFake(), client: client,
          uri: Uri.parse(address));
      await c.initialize();
      await c.handleTranscript('turn on Desk Lamp', bypassWakeWord: true);
      expect(requests, 0, reason: address);
      await c.dispose();
    }
  });

  test('an unknown board address still allows confirmed local BLE control', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{}', 200);
    });
    final speech = _SpeechFake();
    speech.initialization.complete(false);
    final ble = _BleFake();
    final c = controller(speech, _TtsFake(), client: client,
        uri: Uri.parse('http://unconfigured.invalid'), ble: ble);
    final events = <EllieVoiceEvent>[];
    final subscription = c.events.listen(events.add);
    await c.initialize();
    await c.handleTranscript('turn on Desk Lamp', bypassWakeWord: true);
    expect(requests, 0);
    expect(ble.intentCalls, 1);
    expect(events.any((event) => event.reply == 'Desk Lamp is on.'), isTrue);
    await subscription.cancel();
    await c.dispose();
  });

  test('account changes discard in-flight replies and conversation history', () async {
    final pending = Completer<String>();
    final prompts = <List<Map<String, String>>>[];
    final service = LocalLlmService.forTesting(generateReply: (messages, {required allowDeviceCommand}) {
      prompts.add(messages);
      return prompts.length == 1 ? pending.future : Future.value('{"reply":"Hello"}');
    });
    await service.resetForAccountChange('alice');
    final oldReply = service.generate('Private message from Alice',
      assistantName: 'Nova', language: EllieLanguage.english, allowDeviceCommand: false);
    await service.resetForAccountChange('bob');
    pending.complete('{"reply":"Private reply to Alice"}');
    expect(await oldReply, isNull);
    await service.generate('Hello from Bob', assistantName: 'Nova',
      language: EllieLanguage.english, allowDeviceCommand: false);
    expect(prompts.last.toString(), isNot(contains('Private message from Alice')));
    expect(prompts.last.toString(), isNot(contains('Private reply to Alice')));
    await service.resetForAccountChange(null);
    expect(await service.generate('Signed out', assistantName: 'Nova',
      language: EllieLanguage.english, allowDeviceCommand: false), isNull);
    service.dispose();
  });

  test('saved assistant preferences are isolated by account', () async {
    final service = LocalLlmService.forTesting(generateReply: (messages, {required allowDeviceCommand}) async => '{"reply":"Hello"}');
    await service.resetForAccountChange('alice');
    await service.saveMemory('Alice private preference');
    await service.resetForAccountChange('bob');
    expect(service.savedMemory, isEmpty);
    await service.saveMemory('Bob preference');
    await service.resetForAccountChange('alice');
    expect(service.savedMemory, 'Alice private preference');
    await service.resetForAccountChange(null);
    expect(service.savedMemory, isEmpty);
    await expectLater(service.saveMemory('No account'), throwsStateError);
    service.dispose();
  });

  test('retry shares an in-flight model initialization', () async {
    final service = LocalLlmService.forTesting();
    final first = service.initialize();
    final retry = service.initialize(retry: true);
    expect(identical(first, retry), isTrue);
    await first;
    expect(service.state, LocalLlmState.unsupported);
    service.dispose();
  });

  test('assistant preference writes exclude initialization and each other', () async {
    final service = LocalLlmService.forTesting();
    final initializing = service.initialize();
    await expectLater(service.saveMemory('Dina'), throwsStateError);
    await initializing;
    final firstSave = service.saveMemory('Dina');
    await expectLater(service.saveMemory('Replacement'), throwsStateError);
    await firstSave;
    expect(service.savedMemory, 'Dina');
    expect((await SharedPreferences.getInstance())
        .getString('assistant_saved_preferences_v1'), 'Dina');
    service.dispose();
  });
}
