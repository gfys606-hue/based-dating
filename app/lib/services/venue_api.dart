import 'api.dart';

/// Venue staff, bars and table requests (supabase/migrations/20261003000023_venues_bars_tables.sql).
class VenueApi {
  VenueApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  // ---------- staff ----------
  static Future<void> apply(String placeId, String role, {String? note}) =>
      _db.rpc('apply_for_venue', params: {'p_place': placeId, 'p_role': role, 'p_note': note});
  static Future<List<Map<String, dynamic>>> myVenues() async => _rows(await _db.rpc('my_venues'));
  static Future<void> setCapacity(String venueId, int? capacity) =>
      _db.rpc('set_venue_capacity', params: {'p_venue': venueId, 'p_capacity': capacity});
  static Future<List<Map<String, dynamic>>> people(String venueId) async =>
      _rows(await _db.rpc('get_venue_people', params: {'p_venue': venueId}));
  static Future<String> requestBar(String venueId, String userId, String reason) async =>
      await _db.rpc('request_bar', params: {'p_venue': venueId, 'p_user': userId, 'p_reason': reason}) as String;
  static Future<List<Map<String, dynamic>>> bars(String venueId) async =>
      _rows(await _db.rpc('get_venue_bars', params: {'p_venue': venueId}));
  static Future<List<Map<String, dynamic>>> tables(String venueId) async =>
      _rows(await _db.rpc('get_venue_tables', params: {'p_venue': venueId}));
  static Future<void> decideTable(String requestId, String decision, {int? size, String? note}) =>
      _db.rpc('decide_table', params: {'p_request': requestId, 'p_decision': decision, 'p_size': size, 'p_note': note});

  // ---------- members ----------
  static Future<void> requestTable(String eventId, int party, {String? note}) =>
      _db.rpc('request_table', params: {'p_event': eventId, 'p_party': party, 'p_note': note});
  static Future<Map<String, dynamic>?> tableStatus(String eventId) async {
    final r = await _db.rpc('event_table_status', params: {'p_event': eventId});
    return r == null ? null : Map<String, dynamic>.from(r as Map);
  }

  static Future<List<Map<String, dynamic>>> myBars() async => _rows(await _db.rpc('my_venue_bars'));
  static Future<void> appeal(String barId, String text) => _db.rpc('appeal_bar', params: {'p_bar': barId, 'p_text': text});

  // ---------- admin ----------
  static Future<List<Map<String, dynamic>>> applications() async => _rows(await _db.rpc('admin_venue_applications'));
  static Future<void> decideApplication(int id, bool ok) =>
      _db.rpc('admin_decide_venue_application', params: {'p_id': id, 'p_ok': ok});
  static Future<List<Map<String, dynamic>>> barRequests() async => _rows(await _db.rpc('admin_bar_requests'));
  static Future<void> decideBar(String barId, String decision, {String? note}) =>
      _db.rpc('admin_decide_bar', params: {'p_bar': barId, 'p_decision': decision, 'p_note': note});
}
