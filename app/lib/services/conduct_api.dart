import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// House rules and conduct strikes (supabase/migrations/20261105000062_house_rules_strikes.sql).
class ConductApi {
  ConductApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static String errorText(Object e) => e is PostgrestException ? e.message : 'Something went wrong. Try again.';

  /// {accepted, rules: [{rule, title, body}]}
  static Future<Map<String, dynamic>> houseRules() async =>
      Map<String, dynamic>.from(await _db.rpc('my_house_rules') as Map);

  static Future<void> accept() => _db.rpc('accept_house_rules');

  /// True when this member has an active conduct strike (shown as a neutral mark on their profile).
  static Future<bool> mark(String userId) async =>
      await _db.rpc('get_conduct_mark', params: {'p_user': userId}) == true;

  /// Your own warnings and strikes.
  static Future<List<Map<String, dynamic>>> mine() async => _rows(await _db.rpc('get_my_conduct'));

  static Future<void> appeal(String strikeId, String text) =>
      _db.rpc('appeal_strike', params: {'p_strike': strikeId, 'p_text': text});

  // ---------- admin ----------
  /// rule: photos | room | respect | real | door | violence. Returns 'warning' or 'strike'.
  static Future<String> record(String userId, String rule, {String? note, bool? serious}) async =>
      await _db.rpc('admin_conduct', params: {'p_user': userId, 'p_rule': rule, 'p_note': note, 'p_serious': serious})
          as String;

  static Future<List<Map<String, dynamic>>> memberConduct(String userId) async =>
      _rows(await _db.rpc('admin_member_conduct', params: {'p_user': userId}));

  static Future<List<Map<String, dynamic>>> appeals() async => _rows(await _db.rpc('admin_strike_appeals'));

  static Future<void> decide(String strikeId, bool lift, {String? note}) =>
      _db.rpc('admin_decide_strike', params: {'p_strike': strikeId, 'p_lift': lift, 'p_note': note});
}

/// The rule names used for strikes, in the order the admin picks from.
const conductRules = {
  'photos': 'Photos without asking',
  'room': 'Shared what happens in the room',
  'respect': 'Disrespected a venue or staff',
  'real': 'Fake profile or selling',
  'door': 'Posted about the app publicly',
  'violence': 'Violence or threats',
};
