import 'dart:convert';
import 'package:flutter/material.dart';
import 'smart_home_design.dart';

class WifiCredentialsCard extends StatefulWidget {
  const WifiCredentialsCard({
    super.key,
    this.ssid = '',
    this.secure = true,
    required this.busy,
    required this.onSave,
    required this.buttonLabel,
  });
  final String ssid, buttonLabel;
  final bool secure, busy;
  final Future<void> Function(String, String) onSave;
  @override
  State<WifiCredentialsCard> createState() => _WifiCredentialsCardState();
}

class _WifiCredentialsCardState extends State<WifiCredentialsCard> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _ssid;
  final _password = TextEditingController();
  bool _visible = false;
  late bool _secure;
  @override
  void initState() {
    super.initState();
    _ssid = TextEditingController(text: widget.ssid);
    _secure = widget.secure;
  }

  @override
  void didUpdateWidget(WifiCredentialsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ssid != widget.ssid || oldWidget.secure != widget.secure) {
      _ssid.text = widget.ssid;
      _secure = widget.secure;
      _password.clear();
    }
  }

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HomeCard(
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _ssid,
            enabled: !widget.busy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi name (SSID)',
              prefixIcon: Icon(Icons.wifi),
            ),
            validator: (s) =>
                s == null || s.isEmpty || utf8.encode(s).length > 32
                ? 'Enter an SSID of 1–32 bytes.'
                : null,
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: const Text(
              'Password protected',
              style: TextStyle(fontSize: 11),
            ),
            value: _secure,
            onChanged: widget.busy
                ? null
                : (v) => setState(() => _secure = v ?? true),
          ),
          if (_secure)
            TextFormField(
              controller: _password,
              enabled: !widget.busy,
              obscureText: !_visible,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Wi-Fi password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _visible ? 'Hide password' : 'Show password',
                  onPressed: () => setState(() => _visible = !_visible),
                  icon: Icon(
                    _visible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
              validator: (v) {
                final p = v ?? '';
                final n = utf8.encode(p).length;
                return (n >= 8 && n <= 63) ||
                        RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(p)
                    ? null
                    : 'Use 8–63 bytes or a 64-character hexadecimal key.';
              },
            ),
          const SizedBox(height: 18),
          HomePrimaryButton(
            label: widget.buttonLabel,
            busy: widget.busy,
            icon: Icons.wifi_rounded,
            onPressed: widget.busy
                ? null
                : () {
                    if (_form.currentState!.validate())
                      widget.onSave(_ssid.text, _secure ? _password.text : '');
                  },
          ),
        ],
      ),
    ),
  );
}
