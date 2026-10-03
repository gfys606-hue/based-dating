import 'dart:typed_data';

import 'api.dart';

/// Server calls for the Based Social modules beyond dating
/// (supabase/migrations/20260927000009_social_modules.sql). Testers only for now.
class SocialApi {
  SocialApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  // ---------- circles ----------
  static Future<List<Map<String, dynamic>>> myCircles() async => _rows(await _db.rpc('get_my_circles'));
  static Future<String> findMyCircle() async => await _db.rpc('find_my_circle') as String;
  static Future<void> joinCircle(String id) => _db.rpc('join_circle', params: {'p_circle': id});
  static Future<void> leaveCircle(String id) => _db.rpc('leave_circle', params: {'p_circle': id});
  static Future<List<Map<String, dynamic>>> circleMembers(String id) async =>
      _rows(await _db.rpc('get_circle_members', params: {'p_circle': id}));

  static Stream<List<Map<String, dynamic>>> circleMessages(String circleId) => _db
      .from('circle_messages')
      .stream(primaryKey: ['id'])
      .eq('circle_id', circleId)
      .order('created_at', ascending: true);

  static Future<void> sendCircleMessage(String circleId, String body) =>
      _db.from('circle_messages').insert({'circle_id': circleId, 'sender_id': Api.me, 'body': body});

  // ---------- events ----------
  static Future<List<Map<String, dynamic>>> events({int km = 50, String? circleId}) async =>
      _rows(await _db.rpc('get_events', params: {'p_km': km, 'p_circle': circleId}));

  static Future<void> createEvent({
    required String title,
    required DateTime startsAt,
    String? details,
    String? place,
    int? topicId,
    String? circleId,
    int? capacity,
    String? audience, // public | circle | friends | inner | custom
    List<String>? invitees,
  }) =>
      _db.rpc('create_event', params: {
        'p_title': title,
        'p_starts_at': startsAt.toUtc().toIso8601String(),
        'p_details': details,
        'p_place': place,
        'p_topic': topicId,
        'p_circle': circleId,
        'p_capacity': capacity,
        'p_audience': audience,
        'p_invitees': invitees,
      });

  static Future<void> rsvp(String eventId, String status) =>
      _db.rpc('rsvp_event', params: {'p_event': eventId, 'p_status': status});
  static Future<void> cancelEvent(String eventId) => _db.rpc('cancel_event', params: {'p_event': eventId});

  /// Weekly free time: {"mon":["evening"], "sat":["morning","afternoon"]}
  static Future<void> saveAvailability(Map<String, List<String>> a) => Api.updateProfile({'availability': a});

  // ---------- market ----------
  static Future<List<Map<String, dynamic>>> listings({String? query, String? category, bool mine = false, int km = 50}) async =>
      _rows(await _db.rpc('get_listings', params: {
        'p_query': (query == null || query.trim().isEmpty) ? null : query.trim(),
        'p_category': category,
        'p_km': km,
        'p_mine': mine,
      }));

  static Future<String> uploadListingPhoto(Uint8List bytes) async {
    final path = '${Api.me}/listing_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _db.storage.from('photos').uploadBinary(path, bytes);
    return path;
  }

  static Future<void> createListing({
    required String title,
    required int priceCents,
    required String category,
    required String condition,
    String? description,
    String? photoPath,
  }) =>
      _db.rpc('create_listing', params: {
        'p_title': title,
        'p_price_cents': priceCents,
        'p_category': category,
        'p_condition': condition,
        'p_description': description,
        'p_photo': photoPath,
      });

  static Future<void> setListingStatus(String id, String status) =>
      _db.rpc('set_listing_status', params: {'p_listing': id, 'p_status': status});
  static Future<String> messageSeller(String listingId) async =>
      await _db.rpc('message_seller', params: {'p_listing': listingId}) as String;
  static Future<List<Map<String, dynamic>>> myThreads() async => _rows(await _db.rpc('get_my_listing_threads'));

  static Stream<List<Map<String, dynamic>>> threadMessages(String threadId) => _db
      .from('listing_messages')
      .stream(primaryKey: ['id'])
      .eq('thread_id', threadId)
      .order('created_at', ascending: true);

  static Future<void> sendThreadMessage(String threadId, String body) =>
      _db.from('listing_messages').insert({'thread_id': threadId, 'sender_id': Api.me, 'body': body});

  // ---------- search ----------
  static Future<Map<String, dynamic>> search(String q) async {
    final res = await _db.rpc('search_all', params: {'p_query': q});
    return res == null ? <String, dynamic>{} : Map<String, dynamic>.from(res as Map);
  }

  static Future<void> setUseActivity(bool on) => Api.updateProfile({'use_activity_for_matching': on});
  static Future<void> clearSearchHistory() => _db.from('search_history').delete().eq('user_id', Api.me);
}

String money(int cents) {
  if (cents == 0) return 'Free';
  final d = cents ~/ 100;
  final c = cents % 100;
  return c == 0 ? '\$$d' : '\$$d.${c.toString().padLeft(2, '0')}';
}
