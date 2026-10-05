import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// Plus / Inner memberships (supabase/migrations/20261005000028_membership.sql, functions/billing).
class MembershipApi {
  MembershipApi._();
  static final _db = Api.db;

  static Map<String, dynamic> _map(dynamic r) => Map<String, dynamic>.from((r as Map?) ?? const {});
  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static Future<Map<String, dynamic>> mine() async => _map(await _db.rpc('my_membership'));

  /// Opens Stripe checkout in the browser. Throws with a readable message if billing isn't set up yet.
  static Future<void> checkout(String tier, {bool yearly = false}) =>
      _open({'action': 'checkout', 'tier': tier, 'period': yearly ? 'year' : 'month'});

  /// Opens Stripe's page to change plan, update the card, or cancel.
  static Future<void> manage() => _open({'action': 'portal'});

  static Future<void> _open(Map<String, dynamic> body) async {
    final res = await _db.functions.invoke('billing', body: body);
    final data = _map(res.data);
    final url = data['url'] as String?;
    if (url == null) throw Exception(data['error'] ?? 'Memberships aren\'t open yet.');
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  static Future<String?> undoPass() async => await _db.rpc('undo_last_pass') as String?;

  static Future<void> startTravel(double lat, double lng, String name, int days) =>
      _db.rpc('start_travel', params: {'p_lat': lat, 'p_lng': lng, 'p_name': name, 'p_days': days});
  static Future<void> endTravel() => _db.rpc('end_travel');

  static Future<bool> innerMark(String userId) async =>
      await _db.rpc('inner_mark', params: {'p_user': userId}) == true;

  // ---------- admin ----------
  static Future<List<Map<String, dynamic>>> members({String? query}) async =>
      _rows(await _db.rpc('admin_members', params: {'p_query': (query ?? '').trim().isEmpty ? null : query!.trim()}));
  static Future<void> grant(String userId, String tier, {int days = 30}) =>
      _db.rpc('admin_grant_membership', params: {'p_user': userId, 'p_tier': tier, 'p_days': days});
  static Future<void> setOpen(bool on) => _db.rpc('admin_set_memberships_open', params: {'p_on': on});
  static Future<void> setFeatured(String venueId, int days) =>
      _db.rpc('admin_set_featured', params: {'p_venue': venueId, 'p_days': days});
}
