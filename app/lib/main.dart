import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/paused_screen.dart';
import 'screens/platform_shell.dart';
import 'services/api.dart';
import 'theme.dart';

// Run with:
// flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJ...
const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: _url,
    anonKey: _anonKey,
    // Implicit flow: the sign-in link carries the session itself, so it works
    // even if the email opens in a different browser (e.g. inside the Gmail app).
    authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  runApp(const BasedApp());
}

class BasedApp extends StatelessWidget {
  const BasedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Based',
      debugShowCheckedModeBanner: false,
      theme: B.theme(),
      home: const AuthGate(),
    );
  }
}

/// Routes the user to the right place based on sign-in and account status.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Api.db.auth.onAuthStateChange,
      builder: (context, _) {
        if (Api.db.auth.currentSession == null) return const AuthScreen();
        return const _StatusRouter();
      },
    );
  }
}

class _StatusRouter extends StatefulWidget {
  const _StatusRouter();
  @override
  State<_StatusRouter> createState() => _StatusRouterState();
}

class _StatusRouterState extends State<_StatusRouter> {
  late Future<Map<String, dynamic>?> _profile = Api.myProfile();

  void _refresh() => setState(() => _profile = Api.myProfile());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _profile,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final p = snap.data;
        final status = p?['status'] as String? ?? 'onboarding';
        switch (status) {
          case 'active':
            // Testers see the full Based Social platform (module tabs on the left).
            if (p?['is_tester'] == true) return PlatformShell(onStatusChanged: _refresh);
            return HomeShell(onStatusChanged: _refresh);
          case 'paused':
          case 'suspended':
          case 'banned':
            return PausedScreen(status: status, reason: p?['pause_reason'] as String?, onFixed: _refresh);
          default:
            return OnboardingScreen(existing: p, onDone: _refresh);
        }
      },
    );
  }
}
