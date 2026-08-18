import 'dart:async';
import 'dart:convert';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../ble_service.dart';
import 'ellie_language.dart';
import 'offline_assistant.dart';

enum EllieOutputMode { phone, esp32, both }

enum EllieVoicePhase { idle, listening, thinking, speaking, error }

class EllieVoiceEvent {
  const EllieVoiceEvent({
    required this.phase,
    required this.language,
    this.transcript,
    this.reply,
    this.error,
    this.warning,
  });

  final EllieVoicePhase phase;
  final EllieLanguage language;
  final String? transcript;
  final String? reply;
  final Object? error;
  final String? warning;
}

class EllieLocalReply {
  const EllieLocalReply({
    required this.handled,
    required this.needsFallback,
    required this.speakerQueued,
    this.reply,
    this.offlineReply,
  });

  factory EllieLocalReply.fromJson(Map<String, dynamic> json) {
    return EllieLocalReply(
      handled: json['handled'] == true,
      needsFallback: json['needsFallback'] == true,
      speakerQueued: json['speakerQueued'] == true,
      reply: json['reply']?.toString(),
      offlineReply: json['offlineReply']?.toString(),
    );
  }

  final bool handled;
  final bool needsFallback;
  final bool speakerQueued;
  final String? reply;
  final String? offlineReply;
}

/// Coordinates bilingual short microphone sessions, deterministic local home
/// control, built-in offline replies, and phone/ESP32 speech output. It never
/// calls a cloud assistant, remote AI model, or OpenAI endpoint.
class EllieVoiceController {
  EllieVoiceController({
    required this.esp32BaseUri,
    this.assistantName = 'Ellie',
    this.bleService,
    this.outputMode = EllieOutputMode.both,
    this.requireWakeWord = true,
    this.conversationWindow = const Duration(seconds: 30),
    EllieLanguageMode languageMode = EllieLanguageMode.automatic,
    http.Client? httpClient,
    SpeechToText? speechToText,
    FlutterTts? flutterTts,
  })  : _languageMode = languageMode,
        _http = httpClient ?? http.Client(),
        _speech = speechToText ?? SpeechToText(),
        _tts = flutterTts ?? FlutterTts();

  final Uri esp32BaseUri;
  final String assistantName;
  final BleService? bleService;
  final EllieOutputMode outputMode;
  final bool requireWakeWord;
  final Duration conversationWindow;

  final http.Client _http;
  final SpeechToText _speech;
  final FlutterTts _tts;
  final StreamController<EllieVoiceEvent> _events =
      StreamController<EllieVoiceEvent>.broadcast();

  EllieLanguageMode _languageMode;
  EllieLanguage _lastDetectedLanguage = EllieLanguage.english;
  EllieLanguage _systemLanguage = EllieLanguage.english;
  EllieLanguage _activeRecognitionLanguage = EllieLanguage.english;
  List<String> _speechLocales = const <String>[];
  List<String> _ttsLanguages = const <String>[];
  bool _initialized = false;
  bool _speechAvailable = false;
  bool _submittedCurrentSpeech = false;
  bool _disposed = false;
  String _lastTranscript = '';
  DateTime _conversationActiveUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<EllieVoiceEvent> get events => _events.stream;
  bool get isListening => _speech.isListening;
  EllieLanguageMode get languageMode => _languageMode;

  bool get _phoneSpeechEnabled =>
      outputMode == EllieOutputMode.phone || outputMode == EllieOutputMode.both;
  bool get _esp32SpeechEnabled =>
      outputMode == EllieOutputMode.esp32 || outputMode == EllieOutputMode.both;

  void setLanguageMode(EllieLanguageMode mode) {
    _languageMode = mode;
    final language = _languageForMode();
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.idle,
      language: language,
    ));
  }

  Future<bool> initialize() async {
    if (_initialized) return _speechAvailable;

    try {
      _speechAvailable = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: (error) => _emit(EllieVoiceEvent(
          phase: EllieVoicePhase.error,
          language: _activeRecognitionLanguage,
          error: error,
        )),
      );

      if (_speechAvailable) {
        final locales = await _speech.locales();
        _speechLocales = locales.map((locale) => locale.localeId).toList();
        final systemLocale = await _speech.systemLocale();
        if (systemLocale != null) {
          _systemLanguage = _languageFromLocale(systemLocale.localeId);
          _lastDetectedLanguage = _systemLanguage;
        }
      }

      final dynamic rawTtsLanguages = await _tts.getLanguages;
      if (rawTtsLanguages is Iterable) {
        _ttsLanguages = rawTtsLanguages.map((value) => '$value').toList();
      }
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.46);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);

      _initialized = true;
      unawaited(_syncAssistantNameToEsp32());
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.idle,
        language: _languageForMode(),
      ));
      return _speechAvailable;
    } catch (error) {
      _speechAvailable = false;
      _initialized = false;
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: _languageForMode(),
        error: error,
      ));
      return false;
    }
  }

  Future<void> startListening() async {
    if (!await initialize()) {
      final language = _languageForMode();
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: language,
        error: EllieLanguageTools.pick(
          language,
          english: 'Speech recognition is unavailable or permission was denied.',
          arabic: 'التعرّف على الكلام غير متاح أو لم يتم السماح بالميكروفون.',
        ),
      ));
      return;
    }

    await _tts.stop();
    _lastTranscript = '';
    _submittedCurrentSpeech = false;
    _activeRecognitionLanguage = _languageForMode();
    final localeId = _bestSpeechLocale(_activeRecognitionLanguage);

    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.listening,
      language: _activeRecognitionLanguage,
    ));

    try {
      await _listen(localeId: localeId);
    } catch (error) {
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: _activeRecognitionLanguage,
        error: EllieLanguageTools.pick(
          _activeRecognitionLanguage,
          english:
              'Offline speech recognition is unavailable. Install the language pack or type the command instead. ($error)',
          arabic:
              'التعرّف على الكلام بدون إنترنت غير متاح. ثبّتي حزمة اللغة أو اكتبي الأمر بدلاً من ذلك. ($error)',
        ),
      ));
    }
  }

  Future<void> _listen({required String? localeId}) async {
    await _speech.listen(
      onResult: _onSpeechResult,
      localeId: localeId,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      cancelOnError: true,
      onDevice: true,
    );
  }

  Future<void> stopListening() async {
    await _speech.stop();
    if (!_submittedCurrentSpeech && _lastTranscript.trim().isNotEmpty) {
      await _submitCurrentSpeech();
    }
  }

  Future<void> handleTranscript(
    String transcript, {
    bool bypassWakeWord = false,
  }) async {
    final text = transcript.trim();
    if (text.isEmpty || _disposed) return;

    await _speech.stop();
    final language = EllieLanguageTools.detect(text);
    _lastDetectedLanguage = language;
    final hasWakeWord = EllieLanguageTools.hasWakeWord(
      text,
      assistantName: assistantName,
    );
    final conversationIsActive =
        DateTime.now().isBefore(_conversationActiveUntil);

    if (!bypassWakeWord &&
        requireWakeWord &&
        !hasWakeWord &&
        !conversationIsActive) {
      await _deliverReply(
        EllieLanguageTools.pick(
          language,
          english: 'Say $assistantName first, then your request.',
          arabic: 'قولي $assistantName أولاً، ثم اطلبي ما تريدين.',
        ),
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
      return;
    }

    if (hasWakeWord || conversationIsActive || bypassWakeWord) {
      _conversationActiveUntil = DateTime.now().add(conversationWindow);
    }

    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.thinking,
      language: language,
      transcript: text,
    ));

    EllieLocalReply? local;
    try {
      local = await _sendLocalIntent(text, language);
    } catch (_) {
      local = null;
    }

    if (local?.handled == true && (local?.reply?.trim().isNotEmpty ?? false)) {
      await _deliverReply(
        local!.reply!.trim(),
        language: language,
        esp32AlreadyQueued: local.speakerQueued,
      );
      return;
    }

    if (_looksLikeHardwareCommand(text) &&
        (local == null || local.needsFallback)) {
      await _deliverReply(
        EllieLanguageTools.pick(
          language,
          english:
              "I couldn't safely match that home command, so I didn't change anything.",
          arabic: 'لم أتمكن من تحديد أمر المنزل بأمان، لذلك لم أغيّر أي شيء.',
        ),
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
      return;
    }

    final espFallback = local?.offlineReply?.trim();
    final offlineReply = espFallback?.isNotEmpty == true
        ? OfflineAssistantReply(text: espFallback!, language: language)
        : OfflineAssistant.replyTo(
            text,
            assistantName: assistantName,
            language: language,
          );
    await _deliverReply(
      offlineReply.text,
      language: offlineReply.language,
      esp32AlreadyQueued: false,
      tryEsp32: false,
    );
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    _lastTranscript = result.recognizedWords;
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.listening,
      language: _activeRecognitionLanguage,
      transcript: _lastTranscript,
    ));
    if (result.finalResult) unawaited(_submitCurrentSpeech());
  }

  void _onSpeechStatus(String status) {
    if ((status == SpeechToText.doneStatus ||
            status == SpeechToText.notListeningStatus) &&
        !_submittedCurrentSpeech &&
        _lastTranscript.trim().isNotEmpty) {
      unawaited(_submitCurrentSpeech());
    }
  }

  Future<void> _submitCurrentSpeech() async {
    if (_submittedCurrentSpeech) return;
    _submittedCurrentSpeech = true;
    try {
      await handleTranscript(_lastTranscript);
    } catch (error) {
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: _activeRecognitionLanguage,
        error: error,
      ));
    }
  }

  Future<EllieLocalReply> _sendLocalIntent(
    String text,
    EllieLanguage language,
  ) async {
    // The common ESP8266SAM voice path is English-only. Arabic responses stay
    // local and are spoken by an installed on-device phone voice.
    final speakLocally =
        _esp32SpeechEnabled && language == EllieLanguage.english;
    final payload = <String, dynamic>{
      'text': text,
      'language': language.code,
      'speak': speakLocally,
      'assistantName': assistantName,
    };

    try {
      final response = await _http
          .post(
            esp32BaseUri.resolve('/api/ellie'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(milliseconds: 2500));
      if (response.statusCode != 200) {
        throw StateError('ESP32 returned ${response.statusCode}');
      }
      return EllieLocalReply.fromJson(_decodeObject(response.body));
    } catch (_) {
      final ble = bleService;
      if (ble == null || !ble.isConnected) rethrow;
      final response = await ble.sendEllieText(
        text,
        speak: speakLocally,
        assistantName: assistantName,
      );
      return EllieLocalReply.fromJson(response);
    }
  }

  Future<void> _syncAssistantNameToEsp32() async {
    final payload = jsonEncode(<String, dynamic>{
      'assistantName': assistantName,
    });
    try {
      final response = await _http
          .post(
            esp32BaseUri.resolve('/api/assistant/name'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(const Duration(milliseconds: 1500));
      if (response.statusCode >= 200 && response.statusCode < 300) return;
    } catch (_) {
      // BLE below is the local fallback when the controller LAN IP is unknown.
    }

    final ble = bleService;
    if (ble == null || !ble.isConnected) return;
    try {
      await ble.setAssistantName(assistantName);
    } catch (_) {
      // Every later assistant command includes the name and retries the sync.
    }
  }

  Future<void> _deliverReply(
    String reply, {
    required EllieLanguage language,
    required bool esp32AlreadyQueued,
    bool tryEsp32 = true,
  }) async {
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.speaking,
      language: language,
      reply: reply,
    ));
    await _speech.stop();

    final tasks = <Future<void>>[];
    if (_phoneSpeechEnabled) {
      tasks.add(_speakOnPhone(reply, language));
    }
    if (_esp32SpeechEnabled && !esp32AlreadyQueued && tryEsp32) {
      tasks.add(_speakOnEsp32(reply, language));
    }

    String? warning;
    for (final task in tasks) {
      try {
        await task;
      } catch (_) {
        warning = EllieLanguageTools.pick(
          language,
          english: 'One voice output was unavailable.',
          arabic: 'تعذّر تشغيل أحد مخارج الصوت.',
        );
      }
    }
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.idle,
      language: language,
      reply: reply,
      warning: warning,
    ));
  }

  Future<void> _speakOnPhone(String text, EllieLanguage language) async {
    await _tts.stop();
    final locale = _bestTtsLocale(language);
    await _tts.setLanguage(locale);
    await _tts.setSpeechRate(language == EllieLanguage.arabic ? 0.42 : 0.46);
    await _tts.speak(text);
  }

  Future<void> _speakOnEsp32(
    String text,
    EllieLanguage language,
  ) async {
    final clipped = text.length <= 220 ? text : text.substring(0, 220);
    if (language == EllieLanguage.arabic) {
      throw StateError(
        'Arabic ESP32 speech needs locally stored audio; phone TTS remains offline.',
      );
    }

    try {
      final response = await _http
          .post(
            esp32BaseUri.resolve('/api/ellie/speak'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{'text': clipped}),
          )
          .timeout(const Duration(milliseconds: 2500));
      if (response.statusCode >= 200 && response.statusCode < 300) return;
      throw StateError('ESP32 speaker returned ${response.statusCode}');
    } catch (_) {
      final ble = bleService;
      if (ble == null || !ble.isConnected) rethrow;
      final queued = await ble.queueEllieSpeech(clipped);
      if (!queued) throw StateError('ESP32 rejected the speech request.');
    }
  }

  bool _looksLikeHardwareCommand(String text) {
    final normalized = text.toLowerCase();
    final englishAction =
        RegExp(r'\b(turn|switch|power|activate|deactivate)\b')
            .hasMatch(normalized);
    final englishTarget = RegExp(
      r'\b(light|lamp|fan|switch|socket|outlet|plug|device|room|television|tv)\b',
    ).hasMatch(normalized);
    if (englishAction && englishTarget) return true;

    return RegExp(
      r'(شغل|شغلي|افتح|افتحي|اطف|اطفي|اقفل|اقفلي|اغلق|تشغيل|اطفاء)',
    ).hasMatch(normalized);
  }

  EllieLanguage _languageForMode() {
    switch (_languageMode) {
      case EllieLanguageMode.english:
        return EllieLanguage.english;
      case EllieLanguageMode.arabic:
        return EllieLanguage.arabic;
      case EllieLanguageMode.automatic:
        return _lastDetectedLanguage;
    }
  }

  EllieLanguage _languageFromLocale(String locale) {
    return locale.toLowerCase().startsWith('ar')
        ? EllieLanguage.arabic
        : EllieLanguage.english;
  }

  String? _bestSpeechLocale(EllieLanguage language) {
    if (_speechLocales.isEmpty) return language.localeFallback;
    return _bestLocale(
      _speechLocales,
      language == EllieLanguage.arabic
          ? const <String>['ar-EG', 'ar-SA', 'ar']
          : const <String>['en-US', 'en-GB', 'en'],
    );
  }

  String _bestTtsLocale(EllieLanguage language) {
    if (_ttsLanguages.isEmpty) return language.localeFallback;
    return _bestLocale(
          _ttsLanguages,
          language == EllieLanguage.arabic
              ? const <String>['ar-EG', 'ar-SA', 'ar']
              : const <String>['en-US', 'en-GB', 'en'],
        ) ??
        language.localeFallback;
  }

  String? _bestLocale(List<String> installed, List<String> preferred) {
    String normalize(String value) => value.toLowerCase().replaceAll('_', '-');

    for (final requested in preferred) {
      final normalizedRequested = normalize(requested);
      for (final candidate in installed) {
        if (normalize(candidate) == normalizedRequested) return candidate;
      }
    }
    final prefix = preferred.last.toLowerCase();
    for (final candidate in installed) {
      if (normalize(candidate).startsWith(prefix)) return candidate;
    }
    return null;
  }

  Map<String, dynamic> _decodeObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('Expected a JSON object.');
    return decoded.cast<String, dynamic>();
  }

  void _emit(EllieVoiceEvent event) {
    if (!_disposed) _events.add(event);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _speech.cancel();
    await _tts.stop();
    _http.close();
    await _events.close();
  }
}
