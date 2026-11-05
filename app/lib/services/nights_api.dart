import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// Nights out (supabase/migrations/20261105000060_nights_plans_perks.sql):
/// the morning recap and night ratings, the venue plans view, and slow-night perks.
class NightsApi {
  NightsApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static String errorText(Object e) => e is PostgrestException ? e.message : 'Something went wrong. Try again.';

  /// Your latest night to look back on: {place_id, place_name, night, last_night} or null.
  static Future<Map<String, dynamic>?> recap() async {
    final r = await _db.rpc('get_night_recap');
    return r == null ? null : Map<String, dynamic>.from(r as Map);
  }

  /// track: new_people | my_people.
  /// rating: opened_doors | good_room | quiet_room (new_people), unforgettable | good_night | just_okay (my_people).
  static Future<void> rate(String placeId, String night, String track, String rating, {bool? met}) =>
      _db.rpc('rate_night', params: {
        'p_place': placeId,
        'p_night': night,
        'p_track': track,
        'p_rating': rating,
        'p_met': met,
      });

  static Future<void> skip(String placeId, String night) =>
      _db.rpc('skip_night_recap', params: {'p_place': placeId, 'p_night': night});

  /// One row per place per night: {place_id, name, address, lat, lng, night, going, friends: [{user_id, name, photo}],
  /// me_going, partner, perk, perk_details, nights}
  static Future<List<Map<String, dynamic>>> plans({int days = 3}) async =>
      _rows(await _db.rpc('get_venue_plans', params: {'p_days': days, 'p_km': 25}));

  // ---------- venue staff ----------
  /// Post a members-only perk for a quiet night. Returns how many members were told.
  static Future<int> postPerk(String venueId, String title, {String? details, String? night}) async =>
      (await _db.rpc('post_venue_perk', params: {
        'p_venue': venueId,
        'p_title': title,
        'p_details': details,
        'p_night': night,
      }) as num)
          .toInt();

  static Future<void> endPerk(String perkId) => _db.rpc('end_venue_perk', params: {'p_perk': perkId});

  static Future<List<Map<String, dynamic>>> venuePerks(String venueId) async =>
      _rows(await _db.rpc('get_venue_perks', params: {'p_venue': venueId}));
}

/// The two kinds of night and their three answers (no stars).
const nightTracks = {
  'new_people': ('Met new people', [
    ('opened_doors', 'Opened doors'),
    ('good_room', 'Good room'),
    ('quiet_room', 'Quiet room'),
  ]),
  'my_people': ('Night with my people', [
    ('unforgettable', 'Unforgettable'),
    ('good_night', 'Good night'),
    ('just_okay', 'Just okay'),
  ]),
};
