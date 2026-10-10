import 'api.dart';

/// Usage tracking + the admin Activity dashboard
/// (supabase/migrations/20261010000030_activity_dashboard.sql).
class ActivityApi {
  ActivityApi._();
  static DateTime? _last;

  /// Marks me as active today. Called when the app opens or comes back; at most every 30 minutes.
  static Future<void> touch() async {
    if (Api.db.auth.currentSession == null) return;
    if (_last != null && DateTime.now().difference(_last!) < const Duration(minutes: 30)) return;
    _last = DateTime.now();
    try {
      await Api.db.rpc('touch_active');
    } catch (_) {
      _last = null;
    }
  }

  /// Everything on the Activity screen (admins only — the server refuses anyone else).
  static Future<Map<String, dynamic>> dashboard() async =>
      Map<String, dynamic>.from(await Api.db.rpc('admin_activity') as Map);
}
