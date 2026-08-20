import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../ble_service.dart';
import 'ellie_language.dart';
import 'local_command_proposal_guard.dart';
import 'local_llm_service.dart';
import 'local_music_service.dart';
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
/// control, an optional phone-local LLM, deterministic fallback replies, and
/// phone/ESP32 speech output. It never calls a cloud assistant, remote AI
/// model, or OpenAI endpoint.
class EllieVoiceController {
  EllieVoiceController({
    required this.esp32BaseUri,
    this.assistantName = 'Ellie',
    this.bleService,
    this.musicService,
    this.llmService,
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
  final LocalMusicService? musicService;
  final LocalLlmService? llmService;
  final EllieOutputMode outputMode;
  final bool requireWakeWord;
  final Duration conversationWindow;

  final http.Client _http;
  final SpeechToText _speech;
  final FlutterTts _tts;
  final StreamController<EllieVoiceEvent> _events =
      StreamController<EllieVoiceEvent>.broadcast();
  static const MethodChannel _iosLocalSpeechChannel =
      MethodChannel('smarthome/local_speech');

  EllieLanguageMode _languageMode;
  EllieLanguage _lastDetectedLanguage = EllieLanguage.english;
  EllieLanguage _systemLanguage = EllieLanguage.english;
  EllieLanguage _activeRecognitionLanguage = EllieLanguage.english;
  List<String> _speechLocales = const <String>[];
  List<String> _ttsLanguages = const <String>[];
  AudioSession? _audioSession;
  bool _initialized = false;
  bool _speechAvailable = false;
  bool _ttsReady = false;
  Object? _lastTtsError;
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

    _initialized = true;
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
    } catch (error) {
      _speechAvailable = false;
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: _languageForMode(),
        error: error,
      ));
    }

    // Microphone permission and text-to-speech are independent. A denied or
    // unavailable speech recognizer must not disable typed commands or replies.
    await _initializePhoneTts();
    unawaited(_syncAssistantNameToEsp32());
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.idle,
      language: _languageForMode(),
      warning: !_ttsReady && _phoneSpeechEnabled
          ? EllieLanguageTools.pick(
              _languageForMode(),
              english:
                  'Phone voice needs attention. Tap the speaker button to retry.',
              arabic: 'صوت الهاتف يحتاج إلى ضبط. اضغطي زر السماعة للمحاولة.',
            )
          : null,
    ));
    return _speechAvailable;
  }

  Future<void> _initializePhoneTts() async {
    if (!_phoneSpeechEnabled || _ttsReady) return;
    try {
      final dynamic rawTtsLanguages = await _tts.getLanguages;
      if (rawTtsLanguages is Iterable) {
        _ttsLanguages = rawTtsLanguages.map((value) => '$value').toList();
      }
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.46);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _configurePhoneAudioSession(activate: false);
      _lastTtsError = null;
      _ttsReady = true;
    } catch (error) {
      _lastTtsError = error;
      _ttsReady = false;
      if (kDebugMode) debugPrint('Phone TTS initialization failed: $error');
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

    _submittedCurrentSpeech = true;
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

    final musicIntent = LocalMusicIntentParser.parse(
      text,
      assistantName: assistantName,
    );
    if (musicIntent != null && musicService != null) {
      await _handleMusicIntent(musicIntent, language);
      return;
    }

    final looksLikeHardware = _looksLikeHardwareCommand(text);
    final looksLikeEspQuery = _looksLikeEspDataQuery(text);
    if (_looksLikeLocalClockRequest(text)) {
      await _deliverConversationOrFallback(
        text,
        language: language,
        allowAi: false,
      );
      return;
    }
    if (!looksLikeHardware && !looksLikeEspQuery) {
      // Normal conversation must not wait for an HTTP timeout or BLE scan.
      // Only a real device/sensor request is routed through the controller.
      await _deliverConversationOrFallback(text, language: language);
      return;
    }

    EllieLocalReply? local;
    Object? localConnectionError;
    try {
      local = await _sendLocalIntent(text, language);
    } catch (error) {
      localConnectionError = error;
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

    if ((looksLikeHardware || looksLikeEspQuery) && local == null) {
      await _deliverReply(
        EllieLanguageTools.pick(
          language,
          english:
              "I can't reach the ESP32. On 4G, turn on Bluetooth and allow Nearby Devices, or join the ESP32's local Wi-Fi, then try again.",
          arabic:
              'لا أستطيع الوصول إلى الـ ESP32. عند استخدام شبكة الهاتف، شغّلي البلوتوث واسمحي بالأجهزة القريبة، أو اتصلي بشبكة الـ ESP المحلية ثم حاولي مرة أخرى.',
        ),
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
      if (kDebugMode && localConnectionError != null) {
        debugPrint('Local ESP32 assistant connection failed: $localConnectionError');
      }
      return;
    }

    if (looksLikeHardware && local?.handled != true) {
      // A local LLM may normalize natural wording, but its output never touches
      // a relay directly. The proposed command is sent back through the ESP32's
      // deterministic room/device parser and must be confirmed there.
      final ai = await _generateLocalAi(
        text,
        language: language,
        allowDeviceCommand: true,
      );
      final proposedCommand = ai?.deviceCommand?.trim();
      if (proposedCommand != null &&
          proposedCommand.isNotEmpty &&
          proposedCommand.toLowerCase() != text.toLowerCase() &&
          LocalCommandProposalGuard.preservesUserScope(text, proposedCommand)) {
        try {
          final validated = await _sendLocalIntent(proposedCommand, language);
          if (validated.handled &&
              (validated.reply?.trim().isNotEmpty ?? false)) {
            await _deliverReply(
              validated.reply!.trim(),
              language: language,
              esp32AlreadyQueued: validated.speakerQueued,
            );
            return;
          }
        } catch (error) {
          if (kDebugMode) {
            debugPrint('ESP32 rejected/local link lost for AI proposal: $error');
          }
        }
      }
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
    await _deliverConversationOrFallback(
      text,
      language: language,
      preferredFallback: espFallback,
      allowAi: false,
    );
  }

  Future<void> _deliverConversationOrFallback(
    String text, {
    required EllieLanguage language,
    String? preferredFallback,
    bool allowAi = true,
  }) async {
    if (allowAi) {
      final aiReply = await _generateLocalAi(
        text,
        language: language,
        allowDeviceCommand: false,
      );
      if (aiReply?.reply.trim().isNotEmpty == true) {
        await _deliverReply(
          aiReply!.reply.trim(),
          language: language,
          esp32AlreadyQueued: false,
          tryEsp32: false,
        );
        return;
      }
    }

    final offlineReply = preferredFallback?.trim().isNotEmpty == true
        ? OfflineAssistantReply(
            text: preferredFallback!.trim(),
            language: language,
          )
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

  Future<LocalLlmResult?> _generateLocalAi(
    String text, {
    required EllieLanguage language,
    required bool allowDeviceCommand,
  }) async {
    final service = llmService;
    if (service == null || !service.isReady) return null;
    try {
      return await service.generate(
        text,
        assistantName: assistantName,
        language: language,
        allowDeviceCommand: allowDeviceCommand,
      );
    } catch (error) {
      if (kDebugMode) debugPrint('Local on-device model failed: $error');
      return null;
    }
  }

  Future<void> _handleMusicIntent(
    LocalMusicIntent intent,
    EllieLanguage language,
  ) async {
    try {
      final plan = await musicService!.prepareCommand(
        intent,
        language: language,
      );
      final beforeReply = plan.beforeReply;
      if (beforeReply != null) await beforeReply();
      await _deliverReply(
        plan.reply,
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
      final afterReply = plan.afterReply;
      if (afterReply != null) await afterReply();
    } catch (error) {
      if (kDebugMode) debugPrint('Local music command failed: $error');
      await _deliverReply(
        EllieLanguageTools.pick(
          language,
          english:
              'I could not play that local audio file. Try importing it again as MP3, M4A, WAV, or AAC.',
          arabic:
              'لم أتمكن من تشغيل ملف الصوت المحلي. حاولي إضافته مرة أخرى بصيغة MP3 أو M4A أو WAV أو AAC.',
        ),
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
    }
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
      if (ble == null || !await _ensureBleConnected(ble)) rethrow;
      final response = await ble.sendEllieText(
        text,
        speak: speakLocally,
        assistantName: assistantName,
      );
      return EllieLocalReply.fromJson(response);
    }
  }

  Future<bool> _ensureBleConnected(BleService ble) async {
    if (ble.isConnected) return true;

    try {
      await ble.connect().timeout(const Duration(seconds: 12));
    } catch (_) {
      return false;
    }
    if (ble.isConnected) return true;

    // connect() returns immediately when another part of the dashboard is
    // already scanning. Give that in-flight connection a short time to finish.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (ble.isConnected) return true;
      if (ble.currentStatus != BleStatus.scanning &&
          ble.currentStatus != BleStatus.connecting) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return ble.isConnected;
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
    try {
      await _speech.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // A stale recognition session must never leave the sheet stuck in the
      // speaking phase. TTS below reclaims the iOS playback audio session.
    }

    var resumeMusicAfterSpeech = false;
    if (_phoneSpeechEnabled) {
      try {
        resumeMusicAfterSpeech =
            await musicService?.pauseForAssistant() ?? false;
      } catch (_) {
        resumeMusicAfterSpeech = false;
      }
    }

    var phoneFailed = false;
    var esp32Failed = false;
    if (_phoneSpeechEnabled) {
      try {
        await _speakOnPhone(reply, language);
      } catch (error) {
        phoneFailed = true;
        _lastTtsError = error;
        if (kDebugMode) debugPrint('Phone TTS reply failed: $error');
      }
    }

    if (_esp32SpeechEnabled && !esp32AlreadyQueued && tryEsp32) {
      try {
        await _speakOnEsp32(reply, language);
      } catch (error) {
        esp32Failed = true;
        if (kDebugMode) debugPrint('ESP32 speech reply failed: $error');
      }
    }

    if (resumeMusicAfterSpeech) {
      try {
        await musicService?.resumeAfterAssistant();
      } catch (_) {
        // The reply was still delivered. The user can say "resume music".
      }
    }

    final String? warning;
    if (phoneFailed) {
      warning = EllieLanguageTools.pick(
        language,
        english:
            'Phone voice was unavailable. Turn up media volume, then tap the speaker button to test it.',
        arabic:
            'صوت الهاتف غير متاح. ارفعي صوت الوسائط ثم اضغطي زر السماعة للاختبار.',
      );
    } else if (esp32Failed) {
      warning = EllieLanguageTools.pick(
        language,
        english: 'Phone voice worked; the optional ESP32 speaker was unavailable.',
        arabic: 'صوت الهاتف يعمل، لكن سماعة الـ ESP32 الاختيارية غير متاحة.',
      );
    } else {
      warning = null;
    }
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.idle,
      language: language,
      reply: reply,
      warning: warning,
    ));
  }

  Future<void> _speakOnPhone(String text, EllieLanguage language) async {
    try {
      if (!_ttsReady) await _initializePhoneTts();
      if (!_ttsReady) {
        throw StateError(
          'Phone text-to-speech is not ready. ${_lastTtsError ?? ''}',
        );
      }

      await _tts.stop();
      await _releaseIosRecognitionSession();
      await _configurePhoneAudioSession(activate: true);
      final locale = _bestTtsLocale(language);
      final dynamic languageAvailable = await _tts.isLanguageAvailable(locale);
      if (languageAvailable != true && languageAvailable != 1) {
        throw StateError(
          language == EllieLanguage.arabic
              ? 'Install an Arabic system voice in the phone settings.'
              : 'Install an English system voice in the phone settings.',
        );
      }
      await _tts.setLanguage(locale);
      await _tts.setVolume(1.0);
      await _tts.setSpeechRate(language == EllieLanguage.arabic ? 0.42 : 0.46);
      final timeoutSeconds = (8 + (text.length ~/ 8)).clamp(10, 36).toInt();
      final result = await _tts
          .speak(text)
          .timeout(Duration(seconds: timeoutSeconds));
      if (result != 1) {
        throw StateError('The phone text-to-speech engine did not start.');
      }
    } catch (flutterTtsError) {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) rethrow;
      try {
        await _tts.stop();
      } catch (_) {
        // Continue to the native iOS fallback even if the plugin is wedged.
      }
      if (kDebugMode) {
        debugPrint('flutter_tts failed; using native iOS speech: $flutterTtsError');
      }
      await _speakWithNativeIos(text, language);
    }
  }

  Future<void> _releaseIosRecognitionSession() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    // speech_to_text temporarily owns the iOS recording session. Cancel fully,
    // then allow AVAudioSession to settle before claiming playback.
    try {
      await _speech.cancel();
    } catch (_) {
      // The recognizer may already be fully stopped.
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  Future<void> _speakWithNativeIos(
    String text,
    EllieLanguage language,
  ) async {
    await _releaseIosRecognitionSession();
    final timeoutSeconds = (8 + (text.length ~/ 8)).clamp(10, 36).toInt();
    final spoken = await _iosLocalSpeechChannel.invokeMethod<bool>(
      'speak',
      <String, dynamic>{
        'text': text,
        'language': _bestTtsLocale(language),
      },
    ).timeout(Duration(seconds: timeoutSeconds));
    if (spoken != true) {
      throw StateError('The native iPhone voice did not complete playback.');
    }
  }

  Future<void> _configurePhoneAudioSession({required bool activate}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    await _tts.setSharedInstance(true);

    // AVAudioSessionCategoryOptionAllowBluetooth is intended for recording/
    // play-and-record routes and can make a playback-only category fail on
    // some iOS versions. A2DP routes are automatic for playback, so keep only
    // the options that are valid for spoken playback.
    await _tts.setIosAudioCategory(
      IosTextToSpeechAudioCategory.playback,
      <IosTextToSpeechAudioCategoryOptions>[
        IosTextToSpeechAudioCategoryOptions.duckOthers,
        IosTextToSpeechAudioCategoryOptions
            .interruptSpokenAudioAndMixWithOthers,
      ],
      IosTextToSpeechAudioMode.voicePrompt,
    );
    final session = _audioSession ??= await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    if (activate && !await session.setActive(true)) {
      throw StateError('iOS did not grant the assistant audio playback session.');
    }
  }

  Future<void> testPhoneVoice() async {
    await initialize();
    _ttsReady = false;
    await _initializePhoneTts();
    final language = _languageForMode();
    await _deliverReply(
      EllieLanguageTools.pick(
        language,
        english: 'Voice output is working. I am $assistantName.',
        arabic: 'الصوت يعمل الآن. أنا $assistantName.',
      ),
      language: language,
      esp32AlreadyQueued: false,
      tryEsp32: false,
    );
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
    // A customer can give any relay a custom name (for example "Laptop").
    // Treat a clear power phrase as hardware intent without requiring the name
    // to be one of a small hard-coded list of device types.
    final englishPowerPhrase = RegExp(
      r'\b(turn|switch|power)\s+(on|off)\b|'
      r'\b(turn|switch|power)\b.+\b(on|off)\b|'
      r'\b(activate|deactivate|shut down|start up)\b',
    ).hasMatch(normalized);
    if (englishPowerPhrase) return true;

    final englishAction =
        RegExp(r'\b(turn|switch|power|activate|deactivate|start|stop|shut)\b')
            .hasMatch(normalized);
    final englishTarget = RegExp(
      r'\b(light|lamp|fan|switch|socket|outlet|plug|device|room|television|tv)\b',
    ).hasMatch(normalized);
    if (englishAction && englishTarget) return true;

    return RegExp(
      r'(شغل|شغلي|افتح|افتحي|اطف|اطفي|اقفل|اقفلي|اغلق|تشغيل|اطفاء)',
    ).hasMatch(normalized);
  }

  bool _looksLikeEspDataQuery(String text) {
    final normalized = text.toLowerCase();
    final english = RegExp(
      r'\b(temperature|humidity|flame|smoke|sensor|energy usage|power usage)\b|'
      r'\b(is|are)\b.+\b(on|off|active|running)\b|'
      r'\b(status|state)\b.+\b(device|room|light|lamp|fan|tv|socket|plug)\b',
    ).hasMatch(normalized);
    if (english) return true;
    return RegExp(
      r'(الحراره|الحرارة|الرطوبه|الرطوبة|الحريق|الدخان|الحساس|الطاقه|الطاقة|'
      r'شغال|شغاله|شغالة|مفتوح|مقفول|حالة الجهاز|حاله الجهاز)',
    ).hasMatch(normalized);
  }

  bool _looksLikeLocalClockRequest(String text) {
    final normalized = text.toLowerCase();
    return RegExp(
      r'\b(what time|current time|time is it|what date|today.?s date|what day)\b|'
      r'(الساعة كام|كم الساعة|الوقت|التاريخ|النهارده كام|اليوم كام)',
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
