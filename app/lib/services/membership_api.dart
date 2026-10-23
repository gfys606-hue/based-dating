import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// Premium (one plan for the whole platform) and gifts
/// (supabase/migrations/20261020000036_premium_gifts.sql, functions/billing).
class MembershipApi {
  MembershipApi._();
  static final _db = Api.db;

  static Map<String, dynamic> _map(dynamic r) => Map<String, dynamic>.from((r as Map?) ?? const {});
  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static Future<Map<String, dynamic>> mine() async => _map(await _db.rpc('my_membership'));

  /// Opens Stripe checkout in the browser. Throws with a readable message if billing isn't set up yet.
  static Future<void> checkout({bool yearly = false}) =>
      _open({'action': 'checkout', 'tier': 'premium', 'period': yearly ? 'year' : 'month'});

  /// The gift shelf: [{code, name, icon, price_cents}]
  static Future<List<Map<String, dynamic>>> gifts() async =>
      _rows(await _db.from('gift_catalog').select('code, name, icon, price_cents').eq('active', true).order('sort'));

  /// Sends a gift into a match chat. Free (3 a day) until paid plans open; otherwise opens checkout and the
  /// gift arrives once it's paid. Returns true if it was sent right away.
  static Future<bool> sendGift(String matchId, String gift, {String? note}) async {
    final r = _map(await _db.rpc('send_gift', params: {'p_match': matchId, 'p_gift': gift, 'p_note': note}));
    if (r['sent'] == true) return true;
    await _open({'action': 'gift', 'match': matchId, 'gift': gift, 'note': note});
    return false;
  }

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

  // ---------- travel mode (supabase/migrations/20261020000037_travel.sql) ----------
  /// Members in a city who take traveller messages: [{user_id, name, age, photo, distance_km, shared, pending}]
  static Future<List<Map<String, dynamic>>> travelPeople(double lat, double lng) async =>
      _rows(await _db.rpc('travel_browse', params: {'p_lat': lat, 'p_lng': lng}));
  static Future<List<Map<String, dynamic>>> travelSpots(double lat, double lng) async =>
      _rows(await _db.rpc('travel_venues', params: {'p_lat': lat, 'p_lng': lng}));
  static Future<void> sendIntro(String to, double lat, double lng, String city, DateTime? date, String body) =>
      _db.rpc('send_travel_intro', params: {
        'p_to': to,
        'p_lat': lat,
        'p_lng': lng,
        'p_city': city,
        'p_date': date == null ? null : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'p_body': body,
      });
  static Future<List<Map<String, dynamic>>> intros() async => _rows(await _db.rpc('my_travel_intros'));
  static Future<void> answerIntro(String id, bool yes) => _db.rpc('respond_travel_intro', params: {'p_id': id, 'p_accept': yes});

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
