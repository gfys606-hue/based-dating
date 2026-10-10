import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api.dart';

/// Error logs tagged with the screen they happened on, and "Report a problem"
/// (supabase/migrations/20261010000031_errors_feedback.sql).
class Diagnostics {
  Diagnostics._();

  /// The build number baked in by CI (e.g. "181"); "dev" for local builds.
  static const build = String.fromEnvironment('BUILD', defaultValue: 'dev');
  static String get platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  // ---------- where am I? ----------
  /// The left-rail tab you're on (Home, Discover, Talk…), set by the shell.
  static String tab = 'Start';
  static final List<String> _routes = [];
  static final observer = _ScreenObserver();

  /// e.g. "Talk › ChatScreen", or just "Home"
  static String get screen => _routes.isEmpty ? tab : '$tab › ${_routes.last}';

  // ---------- errors ----------
  static final Map<String, DateTime> _recent = {};

  static Future<void> report(Object error, StackTrace? stack) async {
    final msg = error.toString();
    final where = screen;
    final key = '$where|${msg.split('\n').first}';
    final last = _recent[key];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) return; // don't flood
    _recent[key] = DateTime.now();
    try {
      await Api.db.rpc('log_error', params: {
        'p_screen': where,
        'p_message': msg.length > 500 ? msg.substring(0, 500) : msg,
        'p_stack': stack?.toString().split('\n').take(25).join('\n'),
        'p_platform': platform,
        'p_build': build,
      });
    } catch (_) {} // never let error reporting cause an error
  }

  /// Hooks Flutter's error handlers. Call once from main().
  static void install() {
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      prior?.call(details);
      report(details.exception, details.stack);
    };
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      report(error, stack);
      return true;
    };
  }

  // ---------- feedback ----------
  static Future<void> sendFeedback(String kind, String body, {String? screen}) => Api.db.rpc('send_feedback', params: {
        'p_kind': kind,
        'p_body': body,
        'p_screen': screen ?? Diagnostics.screen,
        'p_platform': platform,
        'p_build': build,
      });

  // ---------- admin ----------
  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static Future<Map<String, dynamic>> health() async => Map<String, dynamic>.from(await Api.db.rpc('admin_health') as Map);
  static Future<List<Map<String, dynamic>>> errors({bool resolved = false}) async =>
      _rows(await Api.db.rpc('admin_errors', params: {'p_include_resolved': resolved}));
  static Future<void> resolveError(String fingerprint, bool resolved) =>
      Api.db.rpc('admin_resolve_error', params: {'p_fingerprint': fingerprint, 'p_resolved': resolved});
  static Future<List<Map<String, dynamic>>> feedback({bool done = false}) async =>
      _rows(await Api.db.rpc('admin_feedback', params: {'p_include_done': done}));
  static Future<void> setFeedbackDone(String id, bool done) =>
      Api.db.rpc('admin_set_feedback', params: {'p_id': id, 'p_done': done});
}

/// Keeps track of which screen is open, by the name of the screen's widget.
class _ScreenObserver extends NavigatorObserver {
  String _name(Route<dynamic> route) {
    final n = route.settings.name;
    if (n != null && n.isNotEmpty && n != '/') return n;
    if (route is MaterialPageRoute) {
      try {
        final ctx = navigator?.context;
        if (ctx != null) return route.builder(ctx).runtimeType.toString();
      } catch (_) {}
    }
    if (route is PopupRoute) return 'sheet';
    return route.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.isFirst) return; // the home route is the shell itself
    Diagnostics._routes.add(_name(route));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (Diagnostics._routes.isNotEmpty) Diagnostics._routes.removeLast();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (Diagnostics._routes.isNotEmpty) Diagnostics._routes.removeLast();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (Diagnostics._routes.isNotEmpty) Diagnostics._routes.removeLast();
    if (newRoute != null) Diagnostics._routes.add(_name(newRoute));
  }
}
