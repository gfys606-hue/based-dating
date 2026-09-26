import 'package:flutter/material.dart';

import '../services/api.dart';
import 'onboarding_screen.dart';

/// Shown when the account is paused (usually photos), suspended (under review), or banned.
class PausedScreen extends StatelessWidget {
  const PausedScreen({super.key, required this.status, this.reason, required this.onFixed});
  final String status;
  final String? reason;
  final VoidCallback onFixed;

  @override
  Widget build(BuildContext context) {
    final title = switch (status) {
      'paused' => 'Your account is paused',
      'suspended' => 'Your account is under review',
      _ => 'This account has been banned',
    };
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(reason ?? ''),
              const SizedBox(height: 24),
              if (status == 'paused')
                FilledButton(
                  onPressed: () async {
                    final p = await Api.myProfile();
                    if (!context.mounted) return;
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _FixPhotos(existing: p),
                    ));
                    onFixed();
                  },
                  child: const Text('Fix my photos'),
                ),
              TextButton(onPressed: onFixed, child: const Text('Check again')),
              TextButton(onPressed: () => Api.db.auth.signOut(), child: const Text('Sign out')),
            ],
          ),
        ),
      ),
    );
  }
}

class _FixPhotos extends StatelessWidget {
  const _FixPhotos({this.existing});
  final Map<String, dynamic>? existing;
  @override
  Widget build(BuildContext context) =>
      OnboardingScreen(existing: existing, onDone: () => Navigator.of(context).pop());
}
