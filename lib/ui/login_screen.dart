import 'package:flutter/material.dart';

import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P01 — POS login. Credentials are never stored locally; the server validates
/// them and enforces single-active (session_active_other_device is a distinct
/// error). Login requires a server connection (no offline creds).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.session.login(email: _email.text.trim(), password: _password.text);
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
                    AuthHeader(title: 'Sign in to POS', caption: s.context.outletName?.isNotEmpty == true
                        ? s.context.outletName!
                        : 'Signed into your Gundam outlet'),
                    ErrorBanner(message: s.lastError),
                    TextField(
                      controller: _email,
                      enabled: !s.busy,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _password,
                      enabled: !s.busy,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 24),
                    PrimaryButton(label: 'Sign in', busy: s.busy, icon: Icons.login, onPressed: _submit),
                    const SizedBox(height: 20),
                    const Text('Your credentials stay on the server only.',
                        style: TextStyle(color: PosTheme.slate, fontSize: 13)),
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