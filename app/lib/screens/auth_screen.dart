import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/city_door.dart';
import '../brand.dart';

/// One step to get in: type your email, then the 6-digit code we email you.
/// New and returning people use the same flow -- a new email creates the account,
/// a known email logs in. No passwords, no separate sign-up form.
/// (A password login stays tucked away for accounts that have one, e.g. the Google Play review account.)
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
  String? _error;
  int _resendIn = 0;
  Timer? _resendTimer;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  void _startResendTimer() {
    _resendTimer?.cancel();
    setState(() => _resendIn = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

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
        // Same flow for everyone: a new email creates the account, a known one logs in.
        shouldCreateUser: true,
        // On the website, send people back to this exact page if they tap a link instead.
        emailRedirectTo: kIsWeb ? '${Uri.base.origin}${Uri.base.path}' : null,
      );
      setState(() { _sent = true; _code.clear(); });
      _startResendTimer();
    } on AuthException catch (e) {
      final wait = e.statusCode == '429' || e.message.toLowerCase().contains('rate limit');
      setState(() => _error = wait ? 'Too many codes sent. Wait a minute and try again.' : e.message);
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

  Future<void> _verifyCode() async {
    final code = _code.text.trim();
    if (code.length != 6 || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await Api.db.auth.verifyOTP(email: _email.text.trim(), token: code, type: OtpType.email);
    } on AuthException catch (e) {
      final expired = e.message.toLowerCase().contains('expired') || e.message.toLowerCase().contains('invalid');
      setState(() => _error = expired ? 'That code didn\'t work. Check it, or send a new one.' : e.message);
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
                  TextSpan(text: '${appName}', style: B.display(60)),
                  TextSpan(text: '.', style: B.display(60).copyWith(color: B.gold)),
                ])),
                const SizedBox(height: 10),
                Text('${slogan}', style: B.sloganStyle.copyWith(fontSize: 26, height: 1.15)),
                const SizedBox(height: 10),
                CityDoorLine(style: TextStyle(color: B.muted, fontSize: 13.5, height: 1.4)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: B.cardBox(),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (!_sent) ...[
                      Text('Get in', style: B.heading(22)),
                      const SizedBox(height: 4),
                      Text('New or returning, just enter your email. We\'ll send you a 6-digit code.',
                          style: TextStyle(color: B.muted, fontSize: 13.5, height: 1.4)),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        autocorrect: false,
                        textInputAction: TextInputAction.go,
                        decoration: const InputDecoration(hintText: 'you@example.com'),
                        onSubmitted: (_) => _usePassword ? _passwordLogIn() : _sendLink(),
                      ),
                      const SizedBox(height: 14),
                      if (_usePassword) ...[
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
                        FilledButton(onPressed: _busy ? null : _sendLink, child: Text(_busy ? 'Sending…' : 'Continue')),
                      const SizedBox(height: 8),
                      Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'By continuing, you agree to our '),
                          TextSpan(
                            text: 'Terms of Use',
                            style: const TextStyle(decoration: TextDecoration.underline),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () => launchUrl(Uri.parse('https://based-social.com/terms.html'),
                                  mode: LaunchMode.externalApplication),
                          ),
                          const TextSpan(text: ' and '),
                          TextSpan(
                            text: 'Privacy Policy',
                            style: const TextStyle(decoration: TextDecoration.underline),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () => launchUrl(Uri.parse('https://based-social.com/privacy.html'),
                                  mode: LaunchMode.externalApplication),
                          ),
                          const TextSpan(text: '.'),
                        ]),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => setState(() { _usePassword = !_usePassword; _error = null; }),
                        child: Text(_usePassword ? 'Use an email code instead' : 'I have a password',
                            style: TextStyle(color: B.muted, fontSize: 12.5)),
                      ),
                    ] else ...[
                      Text('Enter your code', style: B.heading(22)),
                      const SizedBox(height: 6),
                      Text.rich(TextSpan(children: [
                        const TextSpan(text: 'We sent a 6-digit code to '),
                        TextSpan(text: _email.text.trim(), style: const TextStyle(fontWeight: FontWeight.w700)),
                        const TextSpan(text: '.'),
                      ]), style: TextStyle(color: B.ink2, height: 1.45)),
                      const SizedBox(height: 4),
                      Text('Not there? Check spam. It can take a minute.', style: TextStyle(color: B.muted, fontSize: 13)),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        maxLength: 6,
                        autofocus: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 8),
                        decoration: const InputDecoration(hintText: '······', counterText: ''),
                        onChanged: (v) {
                          // Accept a pasted code with spaces or dashes, then sign in as soon as there are 6 digits.
                          final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
                          if (digits != v) {
                            _code.value = TextEditingValue(
                              text: digits.length > 6 ? digits.substring(0, 6) : digits,
                              selection: TextSelection.collapsed(offset: digits.length > 6 ? 6 : digits.length),
                            );
                          }
                          if (_code.text.length == 6) _verifyCode();
                        },
                      ),
                      const SizedBox(height: 10),
                      FilledButton(onPressed: _busy ? null : _verifyCode, child: Text(_busy ? 'Checking…' : 'Continue')),
                      const SizedBox(height: 4),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        TextButton(
                          onPressed: _busy ? null : () => setState(() { _sent = false; _code.clear(); _error = null; }),
                          child: const Text('Change email'),
                        ),
                        TextButton(
                          onPressed: (_busy || _resendIn > 0) ? null : _sendLink,
                          child: Text(_resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Resend code'),
                        ),
                      ]),
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
