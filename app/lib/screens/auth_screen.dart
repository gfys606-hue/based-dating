import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api.dart';
import '../theme.dart';

/// Email sign-in (free, built into Supabase).
/// Supabase's default email contains a sign-in LINK. Once a custom email sender
/// (e.g. Resend) is connected, the template can also show a 6-digit code,
/// which the optional code box below accepts.
/// Phone sign-in (one account per number) can replace this later via Twilio.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _usePassword = false; // only for accounts that have a password (e.g. the Google Play review account)
  bool _sent = false;
  bool _busy = false;
  bool _showCode = true;
  bool _logIn = false; // false = create account, true = existing account
  String? _error;

  Future<void> _sendLink() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Enter a valid email.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.db.auth.signInWithOtp(
        email: email,
        // Log in never creates a new account; Sign up does.
        shouldCreateUser: !_logIn,
        // On the website, send people back to this exact page after they tap the link.
        emailRedirectTo: kIsWeb ? '${Uri.base.origin}${Uri.base.path}' : null,
      );
      setState(() => _sent = true);
    } on AuthException catch (e) {
      final noAccount = _logIn &&
          (e.code == 'otp_disabled' || e.message.toLowerCase().contains('signups not allowed'));
      setState(() => _error = noAccount
          ? 'No account with that email yet. Tap "Sign up" to create one.'
          : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _passwordLogIn() async {
    setState(() { _busy = true; _error = null; });
    try {
      await Api.db.auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setMode(bool logIn) {
    if (_busy) return;
    setState(() { _logIn = logIn; _usePassword = false; _error = null; });
  }

  Widget _modeTab(String label, bool logIn) {
    final on = _logIn == logIn;
    return Expanded(
      child: GestureDetector(
        onTap: () => _setMode(logIn),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: on ? B.accent : B.line, width: on ? 2.5 : 1)),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? B.ink : B.muted)),
        ),
      ),
    );
  }

  Future<void> _verifyCode() async {
    setState(() { _busy = true; _error = null; });
    try {
      await Api.db.auth.verifyOTP(email: _email.text.trim(), token: _code.text.trim(), type: OtpType.email);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Spacer(),
                Text.rich(TextSpan(children: [
                  TextSpan(text: 'Based', style: B.display(60)),
                  TextSpan(text: '.', style: B.display(60).copyWith(color: B.accent)),
                ])),
                const SizedBox(height: 10),
                Text('Dating for people who actually show up.', style: TextStyle(fontSize: 20, color: B.ink2, height: 1.35)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: B.cardBox(),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (!_sent) ...[
                      Row(children: [_modeTab('Sign up', false), _modeTab('Log in', true)]),
                      const SizedBox(height: 16),
                      const Text('Email', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(hintText: 'you@example.com'),
                        onSubmitted: (_) => _sendLink(),
                      ),
                      const SizedBox(height: 14),
                      if (_logIn && _usePassword) ...[
                        TextField(
                          controller: _password,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          decoration: const InputDecoration(hintText: 'Password'),
                          onSubmitted: (_) => _passwordLogIn(),
                        ),
                        const SizedBox(height: 14),
                        FilledButton(onPressed: _busy ? null : _passwordLogIn, child: const Text('Log in')),
                      ] else
                        FilledButton(onPressed: _busy ? null : _sendLink, child: Text(_logIn ? 'Email me a login code' : 'Create account')),
                      if (_logIn)
                        TextButton(
                          onPressed: _busy ? null : () => setState(() { _usePassword = !_usePassword; _error = null; }),
                          child: Text(_usePassword ? 'Use an email code instead' : 'Log in with a password',
                              style: TextStyle(color: B.muted, fontSize: 13)),
                        ),
                    ] else ...[
                      Text('Check your email', style: B.heading(22)),
                      const SizedBox(height: 6),
                      Text.rich(TextSpan(children: [
                        const TextSpan(text: 'We sent a 6-digit code to '),
                        TextSpan(text: _email.text.trim(), style: const TextStyle(fontWeight: FontWeight.w700)),
                        const TextSpan(text: '. Enter it below, or tap the link in the email.'),
                      ]), style: TextStyle(color: B.ink2, height: 1.45)),
                      const SizedBox(height: 6),
                      Text('Not there? Check spam. It can take a minute.', style: TextStyle(color: B.muted, fontSize: 13)),
                      const SizedBox(height: 14),
                      if (_showCode) ...[
                        TextField(
                          controller: _code,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          autofocus: true,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 8),
                          decoration: const InputDecoration(hintText: '······', counterText: ''),
                          onChanged: (v) { if (v.trim().length == 6) _verifyCode(); },
                        ),
                        const SizedBox(height: 10),
                        FilledButton(onPressed: _busy ? null : _verifyCode, child: const Text('Sign in')),
                      ] else
                        OutlinedButton(onPressed: () => setState(() => _showCode = true), child: const Text('My email has a code instead')),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _busy ? null : () => setState(() { _sent = false; _code.clear(); }),
                        child: const Text('Use a different email or send again'),
                      ),
                    ],
                    if (_error != null) Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: TextStyle(color: B.urgent)),
                    ),
                  ]),
                ),
                const SizedBox(height: 18),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
