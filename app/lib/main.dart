import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/invite_screens.dart';
import 'screens/onboarding_screen.dart';
import 'screens/paused_screen.dart';
import 'screens/platform_shell.dart';
import 'services/activity_api.dart';
import 'services/diagnostics.dart';
import 'services/api.dart';
import 'services/invites_api.dart';
import 'services/push.dart';
import 'theme.dart';
import 'widgets/door_intro.dart';

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
  Diagnostics.install(); // errors get logged with the screen they happened on
  await B.loadMode();
  await Push.init();
  runApp(const BasedApp());
}

/// App root. Picks light or dark (phone setting, or the user's choice in You → Appearance)
/// and rebuilds everything when that changes.
class BasedApp extends StatefulWidget {
  const BasedApp({super.key});
  @override
  State<BasedApp> createState() => _BasedAppState();
}

class _BasedAppState extends State<BasedApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    B.mode.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    B.mode.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _changed();

  // counts as "active today" each time the app comes back to the foreground
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) ActivityApi.touch();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final system = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    B.isDark = B.mode.value == ThemeMode.dark || (B.mode.value == ThemeMode.system && system == Brightness.dark);
    return MaterialApp(
      key: ValueKey(B.isDark), // light/dark switch rebuilds every screen with the new colors
      title: 'Based',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: Push.messenger,
      navigatorObservers: [Diagnostics.observer],
      theme: B.theme(),
      home: const DoorIntro(child: AuthGate()),
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
        Push.register(); // once per sign-in; asks for notification permission the first time
        ActivityApi.touch();
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
            if (p == null) return _DoorCheck(onDone: _refresh); // brand-new account: needs an invite code first
            return OnboardingScreen(existing: p, onDone: _refresh);
        }
      },
    );
  }
}


/// A new account (no profile yet): ask for an invite code while Based is invite-only, otherwise start onboarding.
class _DoorCheck extends StatefulWidget {
  const _DoorCheck({required this.onDone});
  final VoidCallback onDone;
  @override
  State<_DoorCheck> createState() => _DoorCheckState();
}

class _DoorCheckState extends State<_DoorCheck> {
  late Future<Map<String, dynamic>> _access = InvitesApi.access();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _access,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final a = snap.data ?? const {'invite_only': true, 'redeemed': false};
        if (a['invite_only'] == true && a['redeemed'] != true) {
          return InviteGateScreen(onDone: () => setState(() => _access = InvitesApi.access()));
        }
        return OnboardingScreen(existing: null, onDone: widget.onDone);
      },
    );
  }
}
