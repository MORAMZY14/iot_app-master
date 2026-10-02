import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ellie_language.dart';
import 'local_music_storage.dart';

enum LocalMusicAction { play, pause, resume, stop, next, previous, status }

class LocalMusicIntent {
  const LocalMusicIntent(this.action, {this.requestedTitle});

  final LocalMusicAction action;
  final String? requestedTitle;
}

/// Deterministic bilingual parser for music commands. It intentionally handles
/// only local playback and never calls Spotify, Apple Music, OpenAI, or a URL.
class LocalMusicIntentParser {
  LocalMusicIntentParser._();

  static LocalMusicIntent? parse(
    String input, {
    required String assistantName,
  }) {
    var text = _normalize(input);
    final wakeName = _normalize(assistantName);
    if (wakeName.isNotEmpty) {
      text = text.replaceFirst(
        RegExp('(^| )${RegExp.escape(wakeName)}(?= |\$)'),
        ' ',
      );
      text = _normalize(text);
    }
    text = text.replaceFirst(
      RegExp(
        r'^(?:hey |please |can you |could you |would you |يا |ممكن |لو سمحت |من فضلك )+',
      ),
      '',
    );
    text = _normalize(text);

    final mentionsEnglishMusic = RegExp(
      r'\b(music|song|songs|track|tracks)\b',
    ).hasMatch(text);
    final mentionsArabicMusic = _containsAny(text, const <String>[
      'موسيقي',
      'الموسيقي',
      'اغنيه',
      'الاغنيه',
      'اغاني',
      'الاغاني',
    ]);
    final mentionsMusic = mentionsEnglishMusic || mentionsArabicMusic;

    if (mentionsMusic &&
        (_containsAny(text, const <String>[
              'pause music',
              'pause the music',
              'pause song',
              'وقف الموسيقي',
              'وقفي الموسيقي',
              'وقف الاغنيه',
              'وقفي الاغنيه',
            ]) ||
            text == 'pause')) {
      return const LocalMusicIntent(LocalMusicAction.pause);
    }

    if (mentionsMusic &&
        _containsAny(text, const <String>[
          'stop music',
          'stop the music',
          'stop song',
          'turn off music',
          'turn the music off',
          'اطفي الموسيقي',
          'اقفل الموسيقي',
          'اغلق الموسيقي',
          'اطفي الاغنيه',
          'اقفل الاغنيه',
        ])) {
      return const LocalMusicIntent(LocalMusicAction.stop);
    }

    if (_containsAny(text, const <String>[
      'next song',
      'next track',
      'play next',
      'الاغنيه التاليه',
      'الاغنيه اللي بعدها',
      'شغل اللي بعدها',
    ])) {
      return const LocalMusicIntent(LocalMusicAction.next);
    }

    if (_containsAny(text, const <String>[
      'previous song',
      'previous track',
      'last song',
      'play previous',
      'الاغنيه السابقه',
      'الاغنيه اللي قبلها',
      'شغل اللي قبلها',
    ])) {
      return const LocalMusicIntent(LocalMusicAction.previous);
    }

    if (mentionsMusic &&
        _containsAny(text, const <String>[
          'resume music',
          'continue music',
          'continue the music',
          'كمل الموسيقي',
          'كملي الموسيقي',
          'استأنف الموسيقي',
          'استأنفي الموسيقي',
        ])) {
      return const LocalMusicIntent(LocalMusicAction.resume);
    }

    if (_containsAny(text, const <String>[
      'what is playing',
      'what song is playing',
      'which song is playing',
      'ايه الاغنيه اللي شغاله',
      'ما هي الاغنيه الحاليه',
    ])) {
      return const LocalMusicIntent(LocalMusicAction.status);
    }

    final englishPlay = RegExp(r'^(?:play|start)\s+(.+)$').firstMatch(text);
    if (englishPlay != null) {
      return LocalMusicIntent(
        LocalMusicAction.play,
        requestedTitle: _cleanRequestedTitle(englishPlay.group(1)!),
      );
    }

    final englishTurnOnNamed = RegExp(
      r'^turn on\s+(?:(?:the|a) )?(song|track|music)(?: called| named)?(?:\s+(.+))?$',
    ).firstMatch(text);
    if (englishTurnOnNamed != null) {
      return LocalMusicIntent(
        LocalMusicAction.play,
        requestedTitle: englishTurnOnNamed.group(2)?.trim(),
      );
    }

    if (mentionsEnglishMusic &&
        RegExp(
          r'\bturn\s+(?:the\s+)?music\s+on\b|\bturn\s+on\s+(?:the\s+)?music\b',
        ).hasMatch(text)) {
      return const LocalMusicIntent(LocalMusicAction.play);
    }

    final arabicPlay = RegExp(
      r'^(?:شغل|شغلي|ابدأ|ابدئي)\s+(.+)$',
    ).firstMatch(text);
    if (arabicPlay != null) {
      final remainder = arabicPlay.group(1)!;
      if (_containsAny(remainder, const <String>[
        'موسيقي',
        'الموسيقي',
        'اغنيه',
        'الاغنيه',
        'اغاني',
        'الاغاني',
      ])) {
        return LocalMusicIntent(
          LocalMusicAction.play,
          requestedTitle: _cleanRequestedTitle(remainder),
        );
      }
    }

    return null;
  }

  static String? _cleanRequestedTitle(String value) {
    var title = _normalize(value);
    title = title.replaceFirst(
      RegExp(
        r'^(?:(?:the|a|some) )?(?:song|track|music|اغنيه|الاغنيه|موسيقي|الموسيقي|اغاني|الاغاني)(?: called| named| اسمها)?\s*',
      ),
      '',
    );
    title = title.replaceFirst(RegExp(r'^(?:called|named|اسمها)\s+'), '');
    title = _normalize(title);
    if (title.isEmpty ||
        _containsOnly(title, const <String>[
          'music',
          'song',
          'a song',
          'some music',
          'موسيقي',
          'الموسيقي',
          'اغنيه',
          'الاغنيه',
          'اغاني',
          'الاغاني',
        ])) {
      return null;
    }
    return title;
  }

  static bool _containsAny(String source, List<String> phrases) =>
      phrases.any(source.contains);

  static bool _containsOnly(String source, List<String> phrases) =>
      phrases.any((phrase) => source == phrase);

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\s,،.!?؟;؛:_]+'), ' ')
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه')
      .replaceAll('ـ', '')
      .trim();
}

class LocalMusicTrack {
  const LocalMusicTrack({required this.title, required this.path});

  factory LocalMusicTrack.fromJson(Map<String, dynamic> json) =>
      LocalMusicTrack(
        title: json['title']?.toString().trim() ?? '',
        path: json['path']?.toString().trim() ?? '',
      );

  final String title;
  final String path;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'path': path,
      };
}

typedef LocalMusicCommandAction = Future<void> Function();

class LocalMusicCommandPlan {
  const LocalMusicCommandPlan({
    required this.reply,
    this.beforeReply,
    this.afterReply,
  });

  final String reply;
  final LocalMusicCommandAction? beforeReply;
  final LocalMusicCommandAction? afterReply;
}

/// Persistent, phone-only music library and player. Imported files are copied
/// into the application sandbox and played directly from disk.
class LocalMusicService extends ChangeNotifier {
  LocalMusicService._({
    AudioPlayer? player,
    LocalMusicStorage? storage,
    Future<void> Function()? configureSession,
    Future<FilePickerResult?> Function()? pickTracks,
  })  : _player = player ?? AudioPlayer(),
        _storage = storage ?? LocalMusicStorage(),
        _configureSession = configureSession,
        _pickTracks = pickTracks {
    _playerSubscription = _player.playerStateStream.listen((state) {
      _notifyChanged();
      if (state.playing && state.processingState == ProcessingState.completed) {
        unawaited(_advanceAfterCompletion());
      }
    });
  }

  @visibleForTesting
  factory LocalMusicService.forTesting({
    required AudioPlayer player,
    required LocalMusicStorage storage,
    required Future<void> Function() configureSession,
    required Future<FilePickerResult?> Function() pickTracks,
  }) =>
      LocalMusicService._(
        player: player,
        storage: storage,
        configureSession: configureSession,
        pickTracks: pickTracks,
      );

  static final LocalMusicService instance = LocalMusicService._();
  static const String _libraryPreferenceKey = 'ellie_local_music_library_v1';

  final AudioPlayer _player;
  final LocalMusicStorage _storage;
  final Future<void> Function()? _configureSession;
  final Future<FilePickerResult?> Function()? _pickTracks;
  final List<LocalMusicTrack> _tracks = <LocalMusicTrack>[];
  StreamSubscription<PlayerState>? _playerSubscription;
  AudioSession? _audioSession;
  Future<void>? _initialization;
  bool _autoAdvancing = false;
  bool _importing = false;
  bool _disposed = false;
  Future<void> _operations = Future<void>.value();
  String? _assistantPausedPath;
  int? _currentIndex;

  List<LocalMusicTrack> get tracks =>
      List<LocalMusicTrack>.unmodifiable(_tracks);
  bool get isPlaying => _player.playing;
  LocalMusicTrack? get currentTrack {
    final index = _currentIndex;
    return index == null || index < 0 || index >= _tracks.length
        ? null
        : _tracks[index];
  }

  Future<void> initialize() => _initialization ??= _initializeLibrary();

  Future<void> _initializeLibrary() async {
    try {
      await _loadLibrary();
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _loadLibrary() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_libraryPreferenceKey);
    if (encoded == null || encoded.trim().isEmpty) return;

    List<dynamic> decoded;
    try {
      final value = jsonDecode(encoded);
      if (value is! List) return;
      decoded = value;
    } on FormatException {
      // A damaged preference should not prevent voice/device commands.
      _tracks.clear();
      await _saveLibrary();
      return;
    }
    final loaded = <LocalMusicTrack>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final track = LocalMusicTrack.fromJson(item.cast<String, dynamic>());
      if (track.title.isEmpty || track.path.isEmpty) continue;
      if (await _storage.exists(track.path)) loaded.add(track);
    }
    _tracks
      ..clear()
      ..addAll(loaded);
    await _saveLibrary();
    _notifyChanged();
  }

  Future<int> importTracks() async {
    if (_importing || _disposed) return 0;
    _importing = true;
    try {
      await initialize();
      final result = _pickTracks != null
          ? await _pickTracks!()
          : await FilePicker.platform.pickFiles(
              type: FileType.audio,
              allowMultiple: true,
              withData: false,
              withReadStream: true,
            );
      if (result == null || _disposed) return 0;
      final copied = <({String title, String path})>[];
      var committed = false;
      try {
        try {
          for (final selected in result.files) {
            final storedPath = await _storage.persist(selected);
            if (storedPath == null) continue;
            copied.add((title: _displayTitle(selected.name), path: storedPath));
          }
        } finally {
          if (copied.isNotEmpty) {
            // File I/O stays outside the player queue so importing a large
            // collection does not delay pause or other playback controls.
            await _enqueue(() async {
              final previousLength = _tracks.length;
              try {
                for (final file in copied) {
                  _tracks.add(LocalMusicTrack(
                    title: _uniqueTitle(file.title),
                    path: file.path,
                  ));
                }
                await _saveLibrary();
                committed = true;
              } catch (_) {
                _tracks.removeRange(previousLength, _tracks.length);
                rethrow;
              }
              _notifyChanged();
            });
          }
        }
        return copied.length;
      } finally {
        // Earlier successful copies are committed even if a later stream
        // fails. Copies whose metadata could not be saved are cleaned up.
        if (!committed) {
          for (final file in copied) {
            await _storage.delete(file.path);
          }
        }
      }
    } finally {
      _importing = false;
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _operations.then((_) async {
      if (_disposed) throw StateError('The music player has closed.');
      await initialize();
      return operation();
    });
    // Keep the queue usable after a corrupt file or rejected player operation.
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  void _notifyChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> removeTrack(LocalMusicTrack track) => _enqueue(() async {
    final index = _tracks.indexWhere((item) => item.path == track.path);
    if (index < 0) return;
    _assistantPausedPath = null;
    if (_currentIndex == index) {
      await _player.stop();
    }
    // Keep the entry available for retry if filesystem deletion fails.
    await _storage.delete(track.path);
    if (_currentIndex == index) {
      _currentIndex = null;
    } else if (_currentIndex != null && index < _currentIndex!) {
      _currentIndex = _currentIndex! - 1;
    }
    _tracks.removeAt(index);
    await _saveLibrary();
    _notifyChanged();
  });

  Future<void> playTrack(LocalMusicTrack track) => _enqueue(() async {
    final index = _tracks.indexWhere((item) => item.path == track.path);
    if (index < 0) throw StateError('That local song is no longer available.');
    _assistantPausedPath = null;
    await _playIndex(index);
  });

  Future<void> pause() => _enqueue(() async {
    _assistantPausedPath = null;
    await _player.pause();
    _notifyChanged();
  });

  Future<bool> pauseForAssistant() => _enqueue(() async {
    _assistantPausedPath = null;
    if (!_player.playing) return false;
    await _player.pause();
    _assistantPausedPath = currentTrack?.path;
    _notifyChanged();
    return _assistantPausedPath != null;
  });

  Future<void> resumeAfterAssistant({bool onlyIfPausedByAssistant = false}) =>
      _enqueue(() async {
        if (currentTrack == null || _player.playing) return;
        if (onlyIfPausedByAssistant &&
            currentTrack?.path != _assistantPausedPath) return;
        _assistantPausedPath = null;
        await _configureMusicSession();
        if (_disposed) return;
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        if (_disposed) return;
        unawaited(_player.play().catchError((Object _) {}));
        _notifyChanged();
      });

  Future<LocalMusicCommandPlan> prepareCommand(
    LocalMusicIntent intent, {
    required EllieLanguage language,
  }) async {
    await initialize();
    String pick({required String english, required String arabic}) =>
        EllieLanguageTools.pick(language, english: english, arabic: arabic);

    if (_tracks.isEmpty &&
        intent.action != LocalMusicAction.status &&
        intent.action != LocalMusicAction.pause &&
        intent.action != LocalMusicAction.stop) {
      return LocalMusicCommandPlan(
        reply: pick(
          english:
              'Your local music library is empty. Open the music button and add audio files first.',
          arabic:
              'مكتبة الموسيقى المحلية فارغة. افتحي زر الموسيقى وأضيفي ملفات صوتية أولاً.',
        ),
      );
    }

    switch (intent.action) {
      case LocalMusicAction.play:
        final requested = intent.requestedTitle;
        final track = requested == null
            ? (currentTrack ?? (_tracks.isEmpty ? null : _tracks.first))
            : _findTrack(requested);
        if (track == null) {
          return LocalMusicCommandPlan(
            reply: pick(
              english:
                  'I could not find “$requested” in the local music library. Add it or use its file name.',
              arabic:
                  'لم أجد «$requested» في مكتبة الموسيقى المحلية. أضيفيها أو استخدمي اسم الملف.',
            ),
          );
        }
        return LocalMusicCommandPlan(
          reply: pick(
            english: 'Playing ${track.title}.',
            arabic: 'سأشغل ${track.title}.',
          ),
          beforeReply: _player.playing ? pause : null,
          afterReply: () => playTrack(track),
        );

      case LocalMusicAction.resume:
        final track = currentTrack ?? (_tracks.isEmpty ? null : _tracks.first);
        if (track == null) {
          return LocalMusicCommandPlan(
            reply: pick(
              english: 'There is no local song to resume.',
              arabic: 'لا توجد أغنية محلية لاستكمالها.',
            ),
          );
        }
        return LocalMusicCommandPlan(
          reply: pick(
            english: 'Resuming ${track.title}.',
            arabic: 'سأكمل ${track.title}.',
          ),
          afterReply: () => currentTrack?.path == track.path
              ? resumeAfterAssistant()
              : playTrack(track),
        );

      case LocalMusicAction.pause:
        if (!_player.playing) {
          return LocalMusicCommandPlan(
            reply: pick(
              english: 'The local music is already paused.',
              arabic: 'الموسيقى المحلية متوقفة بالفعل.',
            ),
          );
        }
        return LocalMusicCommandPlan(
          reply: pick(
            english: 'Pausing the music.',
            arabic: 'سأوقف الموسيقى مؤقتاً.',
          ),
          beforeReply: pause,
        );

      case LocalMusicAction.stop:
        if (currentTrack == null) {
          return LocalMusicCommandPlan(
            reply: pick(
              english: 'No local song is selected.',
              arabic: 'لا توجد أغنية محلية محددة.',
            ),
          );
        }
        return LocalMusicCommandPlan(
          reply: pick(
            english: 'Stopping the music.',
            arabic: 'سأوقف الموسيقى.',
          ),
          beforeReply: _stopAndRewind,
        );

      case LocalMusicAction.next:
        final index = _nextIndex(1);
        final track = _tracks[index];
        return LocalMusicCommandPlan(
          reply: pick(
            english: 'Playing next: ${track.title}.',
            arabic: 'سأشغل التالية: ${track.title}.',
          ),
          beforeReply: _player.playing ? pause : null,
          afterReply: () => playTrack(track),
        );

      case LocalMusicAction.previous:
        final index = _nextIndex(-1);
        final track = _tracks[index];
        return LocalMusicCommandPlan(
          reply: pick(
            english: 'Playing previous: ${track.title}.',
            arabic: 'سأشغل السابقة: ${track.title}.',
          ),
          beforeReply: _player.playing ? pause : null,
          afterReply: () => playTrack(track),
        );

      case LocalMusicAction.status:
        final track = currentTrack;
        if (track == null) {
          return LocalMusicCommandPlan(
            reply: pick(
              english: 'No local song is selected.',
              arabic: 'لا توجد أغنية محلية محددة.',
            ),
          );
        }
        return LocalMusicCommandPlan(
          reply: pick(
            english:
                '${track.title} is ${_player.playing ? 'playing' : 'paused'}.',
            arabic:
                '${track.title} ${_player.playing ? 'تعمل الآن' : 'متوقفة مؤقتاً'}.',
          ),
        );
    }
  }

  Future<void> _playIndex(int index) async {
    if (index < 0 || index >= _tracks.length) {
      throw RangeError.index(index, _tracks, 'index');
    }
    final track = _tracks[index];
    final playbackPath = await _storage.resolve(track.path);
    if (playbackPath == null) {
      throw StateError('The local audio file for ${track.title} is missing.');
    }
    if (_disposed) return;
    await _configureMusicSession();
    if (_disposed) return;
    await _player.setFilePath(playbackPath);
    if (_disposed) return;
    _currentIndex = index;
    _notifyChanged();
    unawaited(_player.play().catchError((Object _) {}));
  }

  Future<void> _stopAndRewind() => _enqueue(() async {
    _assistantPausedPath = null;
    await _player.pause();
    await _player.seek(Duration.zero);
    _notifyChanged();
  });

  Future<void> _configureMusicSession() async {
    if (_configureSession != null) {
      await _configureSession!();
      return;
    }
    final session = _audioSession ??= await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    if (!await session.setActive(true)) {
      throw StateError('The phone did not grant audio playback focus.');
    }
  }

  Future<void> _advanceAfterCompletion() async {
    if (_autoAdvancing || _tracks.length < 2 || _currentIndex == null) return;
    _autoAdvancing = true;
    try {
      await _enqueue(() async {
        if (!_player.playing ||
            _player.processingState != ProcessingState.completed ||
            _tracks.length < 2 || _currentIndex == null) return;
        _assistantPausedPath = null;
        await _playIndex(_nextIndex(1));
      });
    } catch (_) {
      // Keep the player stopped if the next imported file was removed/corrupt.
    } finally {
      _autoAdvancing = false;
    }
  }

  int _nextIndex(int direction) {
    if (_tracks.isEmpty) return 0;
    final current = _currentIndex ?? (direction > 0 ? -1 : 0);
    return (current + direction) % _tracks.length;
  }

  LocalMusicTrack? _findTrack(String requestedTitle) {
    final requested = _normalizeTitle(requestedTitle);
    if (requested.isEmpty) return null;
    for (final track in _tracks) {
      if (_normalizeTitle(track.title) == requested) return track;
    }
    final matches = _tracks.where((track) {
      final title = _normalizeTitle(track.title);
      return title.contains(requested) || requested.contains(title);
    }).toList()
      ..sort((a, b) {
        final aDifference =
            (_normalizeTitle(a.title).length - requested.length).abs();
        final bDifference =
            (_normalizeTitle(b.title).length - requested.length).abs();
        return aDifference.compareTo(bDifference);
      });
    return matches.isEmpty ? null : matches.first;
  }

  String _uniqueTitle(String requested) {
    var title = requested.trim().isEmpty ? 'Local song' : requested.trim();
    final existing = _tracks.map((track) => track.title.toLowerCase()).toSet();
    if (!existing.contains(title.toLowerCase())) return title;
    var suffix = 2;
    while (existing.contains('$title ($suffix)'.toLowerCase())) {
      suffix++;
    }
    return '$title ($suffix)';
  }

  String _displayTitle(String fileName) {
    var title = fileName.trim();
    final dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    title = title
        .replaceFirst(RegExp(r'^\d+\s*[-_.]\s*'), '')
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return title.isEmpty ? 'Local song' : title;
  }

  String _normalizeTitle(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u0600-\u06ff]+'), ' ')
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه')
      .trim();

  Future<void> _saveLibrary() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      _libraryPreferenceKey,
      jsonEncode(_tracks.map((track) => track.toJson()).toList()),
    );
    if (!saved) throw StateError('Could not save the local music library.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_playerSubscription?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }
}
