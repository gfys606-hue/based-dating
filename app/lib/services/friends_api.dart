import 'api.dart';

/// Friends: people you've crossed paths with (supabase/migrations/20261002000016_friends.sql).
class FriendsApi {
  FriendsApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  /// {status: self | unavailable | none | outgoing | incoming | friends, met?, friendship_id?, inner?, their_inner?}
  static Future<Map<String, dynamic>> status(String userId) async =>
      Map<String, dynamic>.from(await _db.rpc('friend_status', params: {'p_user': userId}) as Map);

  /// Returns the new status ('outgoing' or 'friends').
  static Future<String> request(String userId) async =>
      await _db.rpc('request_friend', params: {'p_user': userId}) as String;

  static Future<String> respond(String userId, bool accept) async =>
      await _db.rpc('respond_friend', params: {'p_user': userId, 'p_accept': accept}) as String;

  /// Unfriend, or cancel a request you sent.
  static Future<void> remove(String userId) => _db.rpc('remove_friend', params: {'p_user': userId});

  static Future<void> setInner(String userId, bool inner) =>
      _db.rpc('set_inner_circle', params: {'p_user': userId, 'p_inner': inner});

  static Future<void> setVisibility({required bool plans, required bool circles}) =>
      _db.rpc('set_friend_visibility', params: {'p_plans': plans, 'p_circles': circles});

  static Future<Map<String, dynamic>> visibility() async {
    final r = await _db.from('profiles').select('friend_visibility').eq('id', Api.me).single();
    return Map<String, dynamic>.from((r['friend_visibility'] as Map?) ?? const {});
  }

  /// What I share with one friend. Pass null for both to go back to the presets.
  static Future<void> setSharing(String userId, {bool? plans, bool? circles}) =>
      _db.rpc('set_friend_sharing', params: {'p_user': userId, 'p_plans': plans, 'p_circles': circles});

  /// Quiet mode: hours = 0 turns it off, -1 = until I turn it off.
  static Future<void> setQuiet(int hours) => _db.rpc('set_quiet', params: {'p_hours': hours});

  /// When quiet mode ends (null = off). Far-future means "until I turn it off".
  static Future<DateTime?> quietUntil() async {
    final r = await _db.from('profiles').select('quiet_until').eq('id', Api.me).single();
    final v = r['quiet_until'] as String?;
    if (v == null) return null;
    if (v == 'infinity') return DateTime(9999);
    final t = DateTime.tryParse(v)?.toLocal();
    return t == null || t.isBefore(DateTime.now()) ? null : t;
  }

  static Future<List<Map<String, dynamic>>> friends() async => _rows(await _db.rpc('get_friends'));
  static Future<List<Map<String, dynamic>>> requests() async => _rows(await _db.rpc('get_friend_requests'));

  static Future<List<Map<String, dynamic>>> eventPeople(String eventId) async =>
      _rows(await _db.rpc('get_event_people', params: {'p_event': eventId}));

  static Stream<List<Map<String, dynamic>>> messages(String friendshipId) => _db
      .from('friend_messages')
      .stream(primaryKey: ['id'])
      .eq('friendship_id', friendshipId)
      .order('created_at', ascending: true);

  static Future<void> send(String friendshipId, String body) =>
      _db.from('friend_messages').insert({'friendship_id': friendshipId, 'sender_id': Api.me, 'body': body});
}
