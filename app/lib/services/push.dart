import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api.dart';

/// Push notifications (Android). Stays switched off until the Firebase keys are
/// added as GitHub repository variables (FIREBASE_API_KEY, FIREBASE_APP_ID,
/// FIREBASE_SENDER_ID, FIREBASE_PROJECT_ID) and passed in at build time.
class Push {
  Push._();

  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  /// Shows pushes that arrive while the app is open (Android only shows them itself when it's closed).
  static final messenger = GlobalKey<ScaffoldMessengerState>();

  static bool _ready = false;
  static String? _token;
  static StreamSubscription<String>? _refreshSub;
  static StreamSubscription<RemoteMessage>? _foregroundSub;

  static bool get _configured =>
      !kIsWeb && _apiKey.isNotEmpty && _appId.isNotEmpty && _senderId.isNotEmpty && _projectId.isNotEmpty;

  /// Call once at startup.
  static Future<void> init() async {
    if (!_configured) return;
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(apiKey: _apiKey, appId: _appId, messagingSenderId: _senderId, projectId: _projectId),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Push init failed: $e');
    }
  }

  /// Call when someone is signed in: asks permission once, then saves this phone's token.
  static Future<void> register() async {
    if (!_ready || _token != null) return;
    try {
      final m = FirebaseMessaging.instance;
      final perm = await m.requestPermission();
      if (perm.authorizationStatus == AuthorizationStatus.denied) return;
      final t = await m.getToken();
      if (t == null) return;
      _token = t;
      await Api.db.rpc('register_push_token', params: {'p_token': t, 'p_platform': 'android'});

      _refreshSub ??= m.onTokenRefresh.listen((t) {
        _token = t;
        Api.db.rpc('register_push_token', params: {'p_token': t, 'p_platform': 'android'}).catchError((_) => null);
      });
      _foregroundSub ??= FirebaseMessaging.onMessage.listen((msg) {
        final n = msg.notification;
        if (n == null) return;
        messenger.currentState?.showSnackBar(SnackBar(
          content: Text([n.title, n.body].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
        ));
      });
    } catch (e) {
      debugPrint('Push register failed: $e');
    }
  }

  /// Call before signing out so this phone stops getting that account's alerts.
  static Future<void> unregister() async {
    final t = _token;
    _token = null;
    if (!_ready || t == null) return;
    try {
      await Api.db.rpc('unregister_push_token', params: {'p_token': t});
    } catch (_) {}
  }

  /// Sign out (removes this phone's push token first).
  static Future<void> signOut() async {
    await unregister();
    await Api.db.auth.signOut();
  }
}
