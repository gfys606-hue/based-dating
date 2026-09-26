import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api.dart';

/// Email sign-in with a 6-digit code (free, built into Supabase).
/// Phone sign-in (one account per number) can replace this later once an SMS provider like Twilio is connected.
/// Supabase → Authentication → Email Templates → "Magic Link": include {{ .Token }} so the email shows the code.
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
  String? _error;

  Future<void> _sendCode() async {
    setState(() { _busy = true; _error = null; });
    try {
      await Api.db.auth.signInWithOtp(email: _email.text.trim(), shouldCreateUser: true);
      setState(() => _sent = true);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
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
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Text('Based', style: t.displayMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Real people. Real conversations.', style: t.titleMedium),
              const Spacer(),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email', hintText: 'you@example.com'),
                enabled: !_sent,
              ),
              if (_sent) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '6-digit code from your email'),
                ),
              ],
              if (_error != null) Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : (_sent ? _verify : _sendCode),
                child: Text(_sent ? 'Verify' : 'Send code'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
