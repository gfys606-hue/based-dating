import 'api.dart';

/// Invite codes, personal invites, the waitlist and the admin door
/// (supabase/migrations/20261003000019_invite_codes.sql).
class InvitesApi {
  InvitesApi._();
  static final _db = Api.db;

  static Map<String, dynamic> _map(dynamic r) => Map<String, dynamic>.from((r as Map?) ?? const {});
  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  /// {invite_only, redeemed, has_profile}
  static Future<Map<String, dynamic>> access() async => _map(await _db.rpc('my_access'));

  /// {ok, label, inviter}. Throws with a readable message when the code is wrong.
  static Future<Map<String, dynamic>> redeem(String code) async =>
      _map(await _db.rpc('redeem_invite', params: {'p_code': code}));

  static Future<void> joinWaitlist(String email, {String? name, String? note}) =>
      _db.rpc('join_waitlist', params: {'p_email': email, 'p_name': name, 'p_note': note});

  /// {left, frozen, months_left, next_refill, codes: [{code, used, active, expires_at, joined}]}
  static Future<Map<String, dynamic>> myInvites() async => _map(await _db.rpc('get_my_invites'));
  static Future<String> createInvite() async => await _db.rpc('create_personal_invite') as String;

  static Future<void> setShowBadge(bool show) => Api.updateProfile({'show_venue_badge': show});

  // ---------- admin ----------
  static Future<List<String>> createCodes({
    required String kind, // single | limited
    required String label,
    int count = 1,
    int maxUses = 50,
    int? days,
  }) async {
    final r = await _db.rpc('admin_create_codes', params: {
      'p_kind': kind,
      'p_label': label,
      'p_count': count,
      'p_max_uses': maxUses,
      'p_days': days,
    });
    return List<String>.from(r as List);
  }

  static Future<List<Map<String, dynamic>>> stats() async => _rows(await _db.rpc('admin_invite_stats'));
  static Future<List<Map<String, dynamic>>> codes(String label) async =>
      _rows(await _db.rpc('admin_list_codes', params: {'p_label': label}));
  static Future<void> setCodeActive(String code, bool active) =>
      _db.rpc('admin_set_code_active', params: {'p_code': code, 'p_active': active});
  static Future<void> setInviteOnly(bool on) => _db.rpc('admin_set_invite_only', params: {'p_on': on});
  static Future<void> setFullAccess(bool on) => _db.rpc('admin_set_full_access', params: {'p_on': on});
  static Future<List<Map<String, dynamic>>> waitlist() async => _rows(await _db.rpc('admin_waitlist'));
  static Future<String> admit(int id) async => await _db.rpc('admin_admit_waitlist', params: {'p_id': id}) as String;
}
