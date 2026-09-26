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
  bool _sent = false;
  bool _busy = false;
  bool _showCode = false;
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
        shouldCreateUser: true,
        // On the website, send people back to this exact page after they tap the link.
        emailRedirectTo: kIsWeb ? '${Uri.base.origin}${Uri.base.path}' : null,
      );
      setState(() => _sent = true);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                const Text('Dating for people who actually show up.', style: TextStyle(fontSize: 20, color: B.ink2, height: 1.35)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: B.cardBox(),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (!_sent) ...[
                      const Text('Email', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(hintText: 'you@example.com'),
                        onSubmitted: (_) => _sendLink(),
                      ),
                      const SizedBox(height: 14),
                      FilledButton(onPressed: _busy ? null : _sendLink, child: const Text('Email me a sign-in link')),
                    ] else ...[
                      Text('Check your email', style: B.heading(22)),
                      const SizedBox(height: 6),
                      Text.rich(TextSpan(children: [
                        const TextSpan(text: 'We sent a sign-in link to '),
                        TextSpan(text: _email.text.trim(), style: const TextStyle(fontWeight: FontWeight.w700)),
                        const TextSpan(text: '. Open it on this device, in this same browser, and you\'re in.'),
                      ]), style: const TextStyle(color: B.ink2, height: 1.45)),
                      const SizedBox(height: 6),
                      const Text('Not there? Check spam. It can take a minute.', style: TextStyle(color: B.muted, fontSize: 13)),
                      const SizedBox(height: 14),
                      if (_showCode) ...[
                        TextField(
                          controller: _code,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(hintText: '6-digit code from the email'),
                        ),
                        const SizedBox(height: 10),
                        FilledButton(onPressed: _busy ? null : _verifyCode, child: const Text('Verify code')),
                      ] else
                        OutlinedButton(onPressed: () => setState(() => _showCode = true), child: const Text('My email has a code instead')),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _busy ? null : () => setState(() { _sent = false; _showCode = false; _code.clear(); }),
                        child: const Text('Use a different email or send again'),
                      ),
                    ],
                    if (_error != null) Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: const TextStyle(color: B.urgent)),
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
