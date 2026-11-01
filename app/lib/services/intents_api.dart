import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// What you're up for (supabase/migrations/20261101000054_intents.sql):
/// Looking for (right now, 2 weeks at a time), I'm available for, I can, I need — and the people
/// in your city whose picks fit yours, each with the reason.
class IntentsApi {
  IntentsApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static String errorText(Object e) =>
      e is PostgrestException ? e.message : 'Something went wrong. Try again.';

  /// {looking: [{tag,label}], available: [...], skills: [...]} — skills are used for both I can and I need.
  static Future<Map<String, List<Map<String, dynamic>>>> options() async {
    final res = Map<String, dynamic>.from(await _db.rpc('get_intent_options') as Map);
    return {for (final e in res.entries) e.key: _rows(e.value)};
  }

  /// [{kind, tag, label, note, expires_at}]
  static Future<List<Map<String, dynamic>>> mine() async => _rows(await _db.rpc('get_my_intents'));

  /// Replaces your whole list. items: [{kind, tag, note?}]
  static Future<void> save(List<Map<String, dynamic>> items) => _db.rpc('set_my_intents', params: {'p_items': items});

  static Future<void> renew(String tag) => _db.rpc('renew_intent', params: {'p_tag': tag});

  /// Someone's picks for their profile; `fits` marks the ones that match yours.
  static Future<List<Map<String, dynamic>>> ofUser(String userId) async =>
      _rows(await _db.rpc('get_user_intents', params: {'p_user': userId}));

  /// People in your city whose picks fit yours: [{user_id, name, age, photo, reasons, is_friend}]
  static Future<List<Map<String, dynamic>>> matches() async => _rows(await _db.rpc('get_intent_matches'));
}
