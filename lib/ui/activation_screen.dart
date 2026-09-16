import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P00 — Device activation. The user enters the exact 64-char server code
/// (generated via web-app → POS Assets). Client only ever binds by code; all
/// validation is server-side (hash match, single-use, expiry, quota).
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _code = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    _focus.unfocus();
    final code = _code.text.trim();
    if (code.isEmpty) return;
    await widget.session.redeem(code, assetLabel: 'Northstar POS 1');
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListenableBuilder(
                listenable: s,
                builder: (_, __) => Column(
                  children: [
                    const AuthHeader(
                      title: 'Activate this device',
                      caption: 'Enter the activation code from your Operations Setup (POS Assets) to bind this tablet to an outlet.',
                    ),
                    ErrorBanner(message: s.lastError),
                    TextField(
                      controller: _code,
                      focusNode: _focus,
                      enabled: !s.busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLength: 80,
                      textCapitalization: TextCapitalization.none,
                      inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 1.2),
                      decoration: const InputDecoration(
                        labelText: 'Activation code',
                        hintText: '64-character code',
                        prefixIcon: Icon(Icons.qr_code_2),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 8),
                    PrimaryButton(label: 'Activate', busy: s.busy, icon: Icons.verified_outlined, onPressed: _submit),
                    const SizedBox(height: 20),
                    _ServerHint(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text(
      'Connecting to the Gundam server configured at build time.',
      style: TextStyle(color: PosTheme.slate, fontSize: 13),
      textAlign: TextAlign.center,
    );
  }
}