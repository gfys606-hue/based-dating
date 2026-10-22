import 'api.dart';

/// Same-room meets, browse, and owner insights (supabase/migrations/20261021000042_insights_rooms_browse.sql).
class RoomsApi {
  RoomsApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  /// [{id, place, other_age, interests, shared, my_answer, matched, other_id, other_name, other_photo, ask_followup}]
  static Future<List<Map<String, dynamic>>> mine() async => _rows(await _db.rpc('my_room_meets'));

  /// Returns true when you both said yes
  static Future<bool> answer(String id, bool yes) async =>
      await _db.rpc('answer_room_meet', params: {'p_id': id, 'p_yes': yes}) == true;

  static Future<String> followup(String id, {required bool met, required bool friend}) async =>
      await _db.rpc('room_meet_followup', params: {'p_id': id, 'p_met': met, 'p_friend': friend}) as String;

  /// People in your city with Browse on: [{user_id, name, age, photo, distance_km, shared, shared_count}]
  static Future<List<Map<String, dynamic>>> browse({bool dating = false, int offset = 0}) async =>
      _rows(await _db.rpc('browse_people', params: {'p_dating': dating, 'p_limit': 40, 'p_offset': offset}));

  /// Admin: aggregate insights for a city
  static Future<Map<String, dynamic>> insights({String? city, bool includeTest = false}) async =>
      Map<String, dynamic>.from(await _db.rpc('admin_insights', params: {'p_city': city, 'p_include_test': includeTest}) as Map);
}
