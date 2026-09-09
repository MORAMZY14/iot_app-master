import '../ui/smart_home_design.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble_service.dart';
import 'ellie_language.dart';
import 'ellie_voice_controller.dart';
import 'local_llm_service.dart';
import 'assistant_memory_sheet.dart';
import 'local_music_service.dart';

class EllieAssistantSheet extends StatefulWidget {
  const EllieAssistantSheet({
    super.key,
    required this.esp32BaseUri,
    required this.bleService,
    this.assistantName = 'Ellie',
  });

  final Uri esp32BaseUri;
  final BleService bleService;
  final String assistantName;

  @override
  State<EllieAssistantSheet> createState() => _EllieAssistantSheetState();
}

class _EllieAssistantSheetState extends State<EllieAssistantSheet> {
  static const String _languagePreferenceKey = 'ellie_language_mode';

  late final EllieVoiceController _controller;
  late final LocalMusicService _musicService;
  late final LocalLlmService _llmService;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_EllieMessage> _messages = <_EllieMessage>[];

  StreamSubscription<EllieVoiceEvent>? _subscription;
  StreamSubscription<BleStatus>? _bleSubscription;
  late BleStatus _bleStatus;
  EllieLanguageMode _languageMode = EllieLanguageMode.automatic;
  EllieVoiceEvent _event = const EllieVoiceEvent(
    phase: EllieVoicePhase.idle,
    language: EllieLanguage.english,
  );

  @override
  void initState() {
    super.initState();
    _musicService = LocalMusicService.instance;
    _llmService = LocalLlmService.instance;
    _musicService.addListener(_handleMusicChanged);
    _llmService.addListener(_handleLlmChanged);
    _bleStatus = widget.bleService.currentStatus;
    _bleSubscription = widget.bleService.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _bleStatus = status);
    });
    _messages.addAll(<_EllieMessage>[
      _EllieMessage(
        text:
            'Hi, I’m ${widget.assistantName}. Talk naturally or ask me to control devices.',
        language: EllieLanguage.english,
      ),
      _EllieMessage(
        text:
            'مرحباً، أنا ${widget.assistantName}. أضيفي نموذج الذكاء المحلي المدرّب من زر الدماغ، ثم تحدثي بشكل طبيعي أو قولي «اطفي التلفزيون والمروحة».',
        language: EllieLanguage.arabic,
      ),
    ]);
    _controller = EllieVoiceController(
      esp32BaseUri: widget.esp32BaseUri,
      assistantName: widget.assistantName,
      bleService: widget.bleService,
      musicService: _musicService,
      llmService: _llmService,
      // The phone is the dependable bilingual speaker. ESP32 speech remains
      // available in firmware, but is optional hardware and English-only.
      outputMode: EllieOutputMode.phone,
      requireWakeWord: false,
    );
    _subscription = _controller.events.listen(_handleEvent);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    // Loading a large model must not delay microphone/TTS initialization.
    unawaited(
      _llmService.initialize().catchError((Object error) {
        if (mounted) setState(() {});
      }),
    );
    unawaited(
      _musicService.initialize().catchError((Object error) {
        if (mounted) setState(() {});
      }),
    );
    final preferences = await SharedPreferences.getInstance();
    final savedMode = EllieLanguageTools.modeFromStorage(
      preferences.getString(_languagePreferenceKey),
    );
    if (!mounted) return;
    setState(() => _languageMode = savedMode);
    _controller.setLanguageMode(savedMode);
    await _controller.initialize();
  }

  void _handleMusicChanged() {
    if (mounted) setState(() {});
  }

  void _handleLlmChanged() {
    if (mounted) setState(() {});
  }

  void _handleEvent(EllieVoiceEvent event) {
    if (!mounted) return;
    setState(() {
      _event = event;
      if (event.phase == EllieVoicePhase.thinking &&
          event.transcript?.trim().isNotEmpty == true) {
        _appendMessage(
          _EllieMessage(
            text: event.transcript!.trim(),
            language: event.language,
            isUser: true,
          ),
        );
      } else if (event.phase == EllieVoicePhase.speaking &&
          event.reply?.trim().isNotEmpty == true) {
        _appendMessage(
          _EllieMessage(text: event.reply!.trim(), language: event.language),
        );
      } else if (event.phase == EllieVoicePhase.error) {
        _appendMessage(
          _EllieMessage(
            text: _friendlyError(event),
            language: event.language,
            isSystem: true,
          ),
        );
      }
    });
    _scrollToLatest();
  }

  void _appendMessage(_EllieMessage message) {
    final last = _messages.isEmpty ? null : _messages.last;
    if (last != null &&
        last.text == message.text &&
        last.isUser == message.isUser &&
        last.isSystem == message.isSystem) {
      return;
    }
    _messages.add(message);
    if (_messages.length > 100) _messages.removeAt(0);
  }

  String _friendlyError(EllieVoiceEvent event) {
    final raw = event.error?.toString().trim();
    if (raw != null && raw.isNotEmpty) return raw;
    return EllieLanguageTools.pick(
      event.language,
      english: '${widget.assistantName} could not complete that request.',
      arabic: 'لم يتمكن ${widget.assistantName} من إكمال هذا الطلب.',
    );
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _setLanguageMode(EllieLanguageMode mode) async {
    if (_controller.isListening) await _controller.stopListening();
    if (!mounted) return;
    setState(() => _languageMode = mode);
    _controller.setLanguageMode(mode);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_languagePreferenceKey, mode.storageValue);
  }

  Future<void> _toggleListening() async {
    if (_controller.isListening) {
      await _controller.stopListening();
    } else {
      await _controller.startListening();
    }
  }

  Future<void> _sendTypedMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isBusy) return;
    _textController.clear();
    await _controller.handleTranscript(text, bypassWakeWord: true);
  }

  Future<void> _connectBluetooth() async {
    await widget.bleService.connect();
    if (!mounted) return;
    setState(() => _bleStatus = widget.bleService.currentStatus);
  }

  Future<void> _showMusicLibrary() async {
    await _musicService.initialize();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _LocalMusicLibrarySheet(service: _musicService),
    );
  }

  Future<void> _showLocalAiManager() async {
    await _llmService.initialize();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _LocalAiManagerSheet(service: _llmService),
    );
  }

  bool get _isBusy =>
      _event.phase == EllieVoicePhase.thinking ||
      _event.phase == EllieVoicePhase.speaking;

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_bleSubscription?.cancel());
    unawaited(_controller.dispose());
    _musicService.removeListener(_handleMusicChanged);
    _llmService.removeListener(_handleLlmChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listening = _event.phase == EllieVoicePhase.listening;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: (MediaQuery.sizeOf(context).height - keyboard).clamp(
            260.0,
            MediaQuery.sizeOf(context).height,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            child: HomeBackground(
              child: SafeArea(
                top: true,
                child: Column(
                  children: [
                    _buildHeader(context),
                    Expanded(
                      child: CustomScrollView(
                        controller: _scrollController,
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: _connectionCards(context),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            sliver: SliverList.builder(
                              itemCount: _messages.length,
                              itemBuilder: (context, i) => _MessageBubble(
                                message: _messages[i],
                                assistantName: widget.assistantName,
                              ),
                            ),
                          ),
                          if (_messages.isEmpty)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Column(
                                  children: [
                                    HomeGlowIcon(
                                      Icons.smart_toy_outlined,
                                      size: 58,
                                    ),
                                    SizedBox(height: 14),
                                    Text(
                                      'How can I help at home?',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'Ask a question or tell me which device to control.',
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (keyboard == 0) ...[
                      _buildLanguageSelector(context),
                      HomeVoiceButton(
                        large: true,
                        listening: listening,
                        onPressed: _isBusy && !listening
                            ? null
                            : () => unawaited(_toggleListening()),
                        label: listening ? 'Stop listening' : 'Tap to speak',
                      ),
                      _buildStatus(context),
                    ],
                    _buildComposer(context, listening: listening),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionCards(BuildContext context) {
    final ready = _llmService.state == LocalLlmState.ready;
    final connected =
        _bleStatus == BleStatus.connected ||
        _bleStatus == BleStatus.dataUpdated;
    final connecting =
        _bleStatus == BleStatus.scanning || _bleStatus == BleStatus.connecting;
    Widget card(
      IconData icon,
      Color color,
      String title,
      String subtitle,
      VoidCallback? tap,
    ) => Expanded(
      child: InkWell(
        onTap: tap,
        child: HomeCard(
          padding: const EdgeInsets.all(9),
          child: Row(
            children: [
              HomeGlowIcon(icon, color: color, size: 32),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFFA7B8D7),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 15),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        card(
          Icons.bluetooth,
          HomeDesign.blue,
          connected ? 'Bluetooth connected' : 'Bluetooth',
          connecting
              ? 'Connecting…'
              : connected
              ? 'Backup ready'
              : 'Tap to connect',
          connected || connecting ? null : () => unawaited(_connectBluetooth()),
        ),
        const SizedBox(width: 8),
        card(
          Icons.storage_rounded,
          const Color(0xFF1ADCA5),
          ready ? 'Local AI ready' : 'Local AI',
          ready
              ? (_llmService.modelName ?? 'On this device')
              : 'Import your local model',
          _isBusy ? null : () => unawaited(_showLocalAiManager()),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
            ),
            const Spacer(),
            for (final item in [
              (
                Icons.psychology_outlined,
                'Import AI',
                () => unawaited(_showLocalAiManager()),
              ),
              (
                Icons.music_note_outlined,
                'Music',
                () => unawaited(_showMusicLibrary()),
              ),
            ])
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: InkWell(
                  onTap: _isBusy ? null : item.$3,
                  child: Column(
                    children: [
                      HomeGlowIcon(item.$1, size: 34),
                      const SizedBox(height: 4),
                      Text(item.$2, style: const TextStyle(fontSize: 9)),
                    ],
                  ),
                ),
              ),
            PopupMenuButton<String>(
              tooltip: 'Assistant options',
              onSelected: (v) {
                if (v == 'voice')
                  unawaited(_controller.testPhoneVoice());
                else
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => AssistantMemorySheet(
                      initialText: _llmService.savedMemory,
                      onSave: _llmService.saveMemory,
                    ),
                  );
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'memory', child: Text('Memory')),
                PopupMenuItem(value: 'voice', child: Text('Test voice')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 5),
        const Text(
          'Voice Assistant',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 3),
        const Text(
          'Your offline AI for a smarter home',
          style: TextStyle(fontSize: 13, color: Color(0xFFA7B8D7)),
        ),
      ],
    ),
  );
  Widget _buildLanguageSelector(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    child: Row(
      children: [
        for (final mode in EllieLanguageMode.values)
          Expanded(
            child: ReferenceChoice(
              label: EllieLanguageTools.modeLabel(mode),
              icon: mode == EllieLanguageMode.values.first
                  ? Icons.language
                  : Icons.translate,
              selected: mode == _languageMode,
              onTap: () => unawaited(_setLanguageMode(mode)),
            ),
          ),
      ],
    ),
  );
  Widget _buildAiNotice(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final LocalLlmState state = _llmService.state;
    final IconData icon;
    final Color accent;
    final String message;
    switch (state) {
      case LocalLlmState.ready:
        icon = Icons.psychology_rounded;
        accent = Colors.greenAccent.shade400;
        message =
            'Local AI ready: ${_llmService.modelName ?? 'trained model'}. Conversation stays on this phone.';
        break;
      case LocalLlmState.generating:
        icon = Icons.psychology_alt_rounded;
        accent = colors.primary;
        message = 'The local AI is thinking on this phone…';
        break;
      case LocalLlmState.loading:
        icon = Icons.downloading_rounded;
        accent = colors.primary;
        message = 'Loading the private on-device model…';
        break;
      case LocalLlmState.error:
        icon = Icons.error_outline_rounded;
        accent = colors.error;
        message =
            'The local AI needs attention. Open Model to retry or replace it.';
        break;
      case LocalLlmState.unsupported:
        icon = Icons.phone_android_rounded;
        accent = colors.error;
        message = 'Local AI inference is available in the Android/iOS app.';
        break;
      case LocalLlmState.notInstalled:
        icon = Icons.psychology_outlined;
        accent = colors.tertiary;
        message =
            'Import a local AI model to chat offline in English or Arabic.';
        break;
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(11, 8, 7, 8),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 11.5,
                color: colors.onTertiaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: _isBusy ? null : () => unawaited(_showLocalAiManager()),
            child: const Text('Model'),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalNotice(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connected =
        _bleStatus == BleStatus.connected ||
        _bleStatus == BleStatus.dataUpdated;
    final connecting =
        _bleStatus == BleStatus.scanning || _bleStatus == BleStatus.connecting;

    final IconData icon;
    final Color accent;
    final String message;
    if (connected) {
      icon = Icons.bluetooth_connected_rounded;
      accent = Colors.greenAccent.shade400;
      message =
          'ESP32 connected locally by Bluetooth. Device commands are ready.\n'
          'الـ ESP32 متصل محلياً بالبلوتوث، وأوامر الأجهزة جاهزة.';
    } else if (connecting) {
      icon = Icons.bluetooth_searching_rounded;
      accent = colors.primary;
      message =
          'Connecting to the nearby ESP32…\nجارٍ الاتصال بالـ ESP32 القريب…';
    } else if (_bleStatus == BleStatus.adapterOff) {
      icon = Icons.bluetooth_disabled_rounded;
      accent = colors.error;
      message =
          'Bluetooth is off. Turn it on for local commands while the phone is on 4G.\n'
          'البلوتوث مغلق. شغّليه لتنفيذ الأوامر المحلية عند استخدام شبكة الهاتف.';
    } else if (_bleStatus == BleStatus.notFound) {
      icon = Icons.portable_wifi_off_rounded;
      accent = colors.error;
      message =
          'ESP32 not found. Keep it powered, nearby, and advertising, then retry.\n'
          'لم يتم العثور على الـ ESP32. تأكدي من تشغيله وقربه ثم أعيدي المحاولة.';
    } else if (_bleStatus == BleStatus.error) {
      icon = Icons.error_outline_rounded;
      accent = colors.error;
      message =
          'Bluetooth could not connect. Check Nearby Devices permission and retry.\n'
          'تعذر اتصال البلوتوث. تحققي من إذن الأجهزة القريبة ثم أعيدي المحاولة.';
    } else {
      icon = Icons.wifi_tethering_rounded;
      accent = colors.primary;
      message =
          'Commands use local Wi-Fi first. On 4G, Bluetooth connects automatically when you send a device command.\n'
          'تُستخدم شبكة Wi-Fi المحلية أولاً، وعلى شبكة الهاتف سيُجرّب البلوتوث تلقائياً.';
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 20, color: accent),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  message,
                  textAlign: TextAlign.start,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          if (!connected && !connecting) ...<Widget>[
            const SizedBox(height: 5),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () => unawaited(_connectBluetooth()),
                icon: const Icon(Icons.bluetooth_rounded, size: 17),
                label: const Text('Connect · اتصال'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Padding(
        key: ValueKey<String>(_statusText),
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
        child: Text(
          _statusText,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ),
    );
  }

  String get _statusText {
    switch (_event.phase) {
      case EllieVoicePhase.listening:
        return _event.transcript?.trim().isNotEmpty == true
            ? _event.transcript!.trim()
            : (_event.language == EllieLanguage.arabic
                  ? 'أستمع الآن… قولي «${widget.assistantName}» ثم طلبك.'
                  : 'Listening… say “${widget.assistantName}” and your request.');
      case EllieVoicePhase.thinking:
        return _event.language == EllieLanguage.arabic
            ? '${widget.assistantName} يفكّر…'
            : '${widget.assistantName} is thinking…';
      case EllieVoicePhase.speaking:
        return _event.language == EllieLanguage.arabic
            ? '${widget.assistantName} يتحدث…'
            : '${widget.assistantName} is speaking…';
      case EllieVoicePhase.error:
        return _event.language == EllieLanguage.arabic
            ? '${widget.assistantName} يحتاج إلى انتباهك.'
            : '${widget.assistantName} needs your attention.';
      case EllieVoicePhase.idle:
        return _event.warning ??
            (_event.language == EllieLanguage.arabic
                ? 'اضغطي على الميكروفون للتحدث.'
                : 'Tap the microphone to talk.');
    }
  }

  Widget _buildComposer(BuildContext context, {required bool listening}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                enabled: !_isBusy,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => unawaited(_sendTypedMessage()),
                decoration: InputDecoration(
                  hintText: 'Type a message…',
                  prefixIcon: const Icon(Icons.edit_outlined),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send · إرسال',
              onPressed: _isBusy ? null : () => unawaited(_sendTypedMessage()),
              style: IconButton.styleFrom(
                backgroundColor: HomeDesign.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 48),
              ),
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
      );
}

class _LocalAiManagerSheet extends StatefulWidget {
  const _LocalAiManagerSheet({required this.service});

  final LocalLlmService service;

  @override
  State<_LocalAiManagerSheet> createState() => _LocalAiManagerSheetState();
}

class _LocalAiManagerSheetState extends State<_LocalAiManagerSheet> {
  bool _working = false;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_handleChanged);
  }

  void _handleChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _importModel() async {
    if (_working) return;
    setState(() => _working = true);
    final imported = await widget.service.importModel();
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          imported
              ? 'Local AI model installed. You can now talk offline.'
              : widget.service.lastError ?? 'No model was selected.',
        ),
      ),
    );
  }

  Future<void> _showUnsupportedImportInfo() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use the phone build for this model'),
        content: const Text(
          'Chrome is available as a user-interface preview in this local-only '
          'build. GGUF and Gemma .task models use Android/iOS CPU '
          'inference, while a browser needs WebGPU and a separately compatible '
          'web model source.\n\nInstall the Android APK or a signed iOS IPA, '
          'then import your .gguf or .task file on that phone.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _retry() async {
    if (_working) return;
    setState(() => _working = true);
    await widget.service.initialize(retry: true);
    if (mounted) setState(() => _working = false);
  }

  Future<void> _removeModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove local AI model?'),
        content: const Text(
          'This deletes the app’s private copy from this phone. Your original laptop model is not changed.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    await widget.service.removeModel();
    if (mounted) setState(() => _working = false);
  }

  @override
  void dispose() {
    widget.service.removeListener(_handleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final state = widget.service.state;
    final ready = widget.service.isReady;
    final modelImportSupported = widget.service.isSupported;
    final busy =
        _working ||
        state == LocalLlmState.loading ||
        state == LocalLlmState.generating;
    final String status;
    switch (state) {
      case LocalLlmState.ready:
        status = 'Ready for private offline conversation';
        break;
      case LocalLlmState.generating:
        status = 'Generating locally on this phone…';
        break;
      case LocalLlmState.loading:
        status = 'Loading and checking the model…';
        break;
      case LocalLlmState.error:
        status = 'Could not load the current model';
        break;
      case LocalLlmState.unsupported:
        status = 'Use an Android or iOS build for local AI inference';
        break;
      case LocalLlmState.notInstalled:
        status = 'No local model installed';
        break;
    }

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.64,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                backgroundColor: ready
                    ? Colors.greenAccent.shade400.withValues(alpha: 0.18)
                    : colors.tertiaryContainer,
                child: Icon(Icons.psychology_rounded, color: colors.tertiary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Private local AI',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text('Qwen GGUF or Gemma · runs on this phone'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  status,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (widget.service.modelName != null) ...<Widget>[
                  const SizedBox(height: 5),
                  Text(
                    widget.service.modelName!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (widget.service.lastError != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    widget.service.lastError!,
                    style: TextStyle(color: colors.error, fontSize: 12),
                  ),
                ],
                if (busy) ...<Widget>[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            modelImportSupported
                ? 'Copy your Qwen3-1.7B Q4_K_M .gguf file to this phone, then tap Import. Use pretrained weights or your laptop fine-tune. Existing Gemma .task models also work. Try Qwen3-0.6B if the larger model is too slow for this phone.'
                : 'This Chrome build previews the interface only. Import and local AI inference are available in the Android and iOS builds.',
            style: TextStyle(height: 1.45),
          ),
          const SizedBox(height: 10),
          const Text(
            'Home-control safety: the AI may rewrite a request, but only the ESP32’s known room/device parser can approve and execute it.',
            style: TextStyle(fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: busy
                ? null
                : modelImportSupported
                ? _importModel
                : _showUnsupportedImportInfo,
            icon: Icon(
              modelImportSupported
                  ? Icons.file_open_rounded
                  : Icons.info_outline_rounded,
            ),
            label: Text(
              modelImportSupported
                  ? ready
                        ? 'Replace model'
                        : 'Import model'
                  : 'Why import is unavailable in Chrome',
            ),
          ),
          if (state == LocalLlmState.error) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : _retry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry current model'),
            ),
          ],
          if (ready) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => unawaited(widget.service.resetConversation()),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Start a new conversation'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: busy ? null : _removeModel,
              icon: Icon(Icons.delete_outline_rounded, color: colors.error),
              label: Text(
                'Remove from this phone',
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LocalMusicLibrarySheet extends StatefulWidget {
  const _LocalMusicLibrarySheet({required this.service});

  final LocalMusicService service;

  @override
  State<_LocalMusicLibrarySheet> createState() =>
      _LocalMusicLibrarySheetState();
}

class _LocalMusicLibrarySheetState extends State<_LocalMusicLibrarySheet> {
  bool _importing = false;

  Future<void> _importTracks() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final count = await widget.service.importTracks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? 'No audio files were added.'
                : 'Added $count local ${count == 1 ? 'song' : 'songs'}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import that audio file: $error')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _toggleTrack(LocalMusicTrack track) async {
    try {
      if (widget.service.currentTrack?.path == track.path &&
          widget.service.isPlaying) {
        await widget.service.pause();
      } else {
        await widget.service.playTrack(track);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play ${track.title}: $error')),
      );
    }
  }

  Future<void> _removeTrack(LocalMusicTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove local song?'),
        content: Text(
          'Remove “${track.title}” from this phone? The original file outside the app is not changed.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.service.removeTrack(track);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final tracks = widget.service.tracks;
        final current = widget.service.currentTrack;
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.67,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 12, 10),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.library_music_rounded, color: colors.primary),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Local music library',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Files stay on this phone · الملفات تبقى على الهاتف',
                            style: TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _importing ? null : _importTracks,
                      icon: _importing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_rounded),
                      label: const Text('Add songs'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    'Try: “Play Blinding Lights”, “pause music”, “next song”\n'
                    'جرّبي: «شغلي أغنية Blinding Lights» أو «وقفي الموسيقى»',
                    style: TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: tracks.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text(
                            'No local songs yet. Tap “Add songs” and choose audio files from Files.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                        itemCount: tracks.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final track = tracks[index];
                          final selected = current?.path == track.path;
                          final playing = selected && widget.service.isPlaying;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: selected
                                  ? colors.primary
                                  : colors.surfaceContainerHighest,
                              foregroundColor: selected
                                  ? colors.onPrimary
                                  : colors.onSurface,
                              child: Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.music_note_rounded,
                              ),
                            ),
                            title: Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              playing
                                  ? 'Playing locally · تعمل محلياً'
                                  : 'Tap to play · اضغطي للتشغيل',
                            ),
                            onTap: () => unawaited(_toggleTrack(track)),
                            trailing: IconButton(
                              tooltip: 'Remove local song',
                              onPressed: () => unawaited(_removeTrack(track)),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EllieMessage {
  const _EllieMessage({
    required this.text,
    required this.language,
    this.isUser = false,
    this.isSystem = false,
  });

  final String text;
  final EllieLanguage language;
  final bool isUser;
  final bool isSystem;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.assistantName});
  final _EllieMessage message;
  final String assistantName;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 17),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!message.isUser) ...[
          const SizedBox(
            width: 44,
            height: 44,
            child: ReferenceArt(
              asset: 'assets/images/reference_4.png',
              crop: Rect.fromLTWH(166, 439, 86, 88),
            ),
          ),
          const SizedBox(width: 9),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: message.isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (!message.isUser)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    assistantName,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: message.isSystem
                      ? Theme.of(context).colorScheme.errorContainer
                      : const Color(0xFF1A2539),
                  gradient: message.isUser ? HomeDesign.gradient : null,
                  border: Border.all(color: HomeDesign.border),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Directionality(
                  textDirection: message.language == EllieLanguage.arabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: Text(
                    message.text,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: message.isSystem
                          ? Theme.of(context).colorScheme.onErrorContainer
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (message.isUser) ...[
          const SizedBox(width: 9),
          const HomeGlowIcon(Icons.person_outline, size: 35),
        ],
      ],
    ),
  );
}
