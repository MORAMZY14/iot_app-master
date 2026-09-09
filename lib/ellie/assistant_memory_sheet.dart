import 'package:flutter/material.dart';

class AssistantMemorySheet extends StatefulWidget {
  const AssistantMemorySheet({
    super.key,
    required this.initialText,
    required this.onSave,
  });
  final String initialText;
  final Future<void> Function(String) onSave;
  @override
  State<AssistantMemorySheet> createState() => _AssistantMemorySheetState();
}

class _AssistantMemorySheetState extends State<AssistantMemorySheet> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  bool _saving = false;
  String? _error;
  Future<void> _save(String value) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(value);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '$error';
        });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Things to remember',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Add your name, interests, or how you like replies. These notes are saved on this phone until you clear them.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            enabled: !_saving,
            minLines: 3,
            maxLines: 5,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: 'Saved preferences',
              border: OutlineInputBorder(),
              hintText:
                  'My name is Omar. I enjoy gardening. Reply in Egyptian Arabic.',
            ),
          ),
          const Text(
            'Saving starts a fresh chat context. Ordinary chats do not automatically change model weights. محادثاتك لا تُستخدم للتدريب تلقائيًا.',
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : () => _save(_text.text),
            child: const Text('Save preferences'),
          ),
          TextButton(
            onPressed: _saving ? null : () => _save(''),
            child: const Text('Forget saved preferences'),
          ),
        ],
      ),
    ),
  );
}
