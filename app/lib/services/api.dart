import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper over the Supabase functions defined in supabase/migrations.
/// All rules (matching, scores, call window, contact filter) live on the server.
class Api {
  Api._();
  static final db = Supabase.instance.client;
  static String get me => db.auth.currentUser!.id;

  // ---------- profile / onboarding ----------
  static Future<Map<String, dynamic>?> myProfile() =>
      db.from('profiles').select().eq('id', me).maybeSingle();

  static Future<void> saveBasics({
    required String name,
    required DateTime birthdate,
    required String gender,
    required List<String> seeking,
  }) =>
      db.from('profiles').upsert({
        'id': me,
        'display_name': name,
        'birthdate': birthdate.toIso8601String().substring(0, 10),
        'gender': gender,
        'seeking': seeking,
      });

  static Future<void> updateProfile(Map<String, dynamic> fields) =>
      db.from('profiles').update(fields).eq('id', me);

  static Future<Map<String, dynamic>> uploadSelfie(Uint8List bytes) async {
    final path = '$me/selfie_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await db.storage.from('selfies').uploadBinary(path, bytes);
    await updateProfile({'selfie_path': path});
    final res = await db.functions.invoke('photo-check', body: {'type': 'selfie'});
    return Map<String, dynamic>.from(res.data as Map);
  }

  static Future<Map<String, dynamic>> uploadPhoto(int position, Uint8List bytes) async {
    final path = '$me/p${position}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await db.storage.from('photos').uploadBinary(path, bytes);
    await db.from('photos').delete().eq('user_id', me).eq('position', position);
    final row = await db
        .from('photos')
        .insert({'user_id': me, 'storage_path': path, 'position': position})
        .select()
        .single();
    final res = await db.functions
        .invoke('photo-check', body: {'type': 'photo', 'photo_id': row['id']});
    return Map<String, dynamic>.from(res.data as Map);
  }

  static Future<List<Map<String, dynamic>>> myPhotos() =>
      db.from('photos').select().eq('user_id', me).order('position');

  static Future<List<Map<String, dynamic>>> topics() =>
      db.from('topics').select().order('name');

  static Future<void> setTopics(Set<int> ids) async {
    await db.from('user_topics').delete().eq('user_id', me);
    await db.from('user_topics').insert([for (final t in ids) {'user_id': me, 'topic_id': t}]);
  }

  static Future<String> completeOnboarding() async =>
      await db.rpc('complete_onboarding') as String;

  // ---------- matching ----------
  static Future<List<Map<String, dynamic>>> matchBatch() async =>
      List<Map<String, dynamic>>.from(await db.rpc('get_match_batch', params: {'p_limit': 10}));

  /// Returns a match id when the like is mutual.
  static Future<String?> like(String userId) async =>
      await db.rpc('like_user', params: {'p_target': userId}) as String?;

  static Future<void> pass(String userId) => db.rpc('pass_user', params: {'p_target': userId});

  static Future<Map<String, dynamic>?> profile(String userId) async {
    final r = await db.rpc('get_profile', params: {'p_user': userId});
    return r == null ? null : Map<String, dynamic>.from(r as Map);
  }

  // ---------- matches / chat ----------
  static Future<List<Map<String, dynamic>>> myMatches() async =>
      List<Map<String, dynamic>>.from(await db.rpc('get_my_matches'));

  static Stream<List<Map<String, dynamic>>> messages(String matchId) => db
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .order('created_at');

  static Future<void> send(String matchId, String body) =>
      db.from('messages').insert({'match_id': matchId, 'sender_id': me, 'body': body});

  /// "Not feeling it" — never penalized.
  static Future<void> notFeelingIt(String matchId) =>
      db.rpc('end_match', params: {'p_match': matchId, 'p_reason': 'not_feeling_it'});

  static Future<List<Map<String, dynamic>>> calls(String matchId) => db
      .from('calls')
      .select()
      .eq('match_id', matchId)
      .inFilter('status', ['proposed', 'accepted'])
      .order('scheduled_for');

  static Future<void> proposeCall(String matchId, DateTime when, String kind) =>
      db.rpc('propose_call', params: {
        'p_match': matchId,
        'p_when': when.toUtc().toIso8601String(),
        'p_kind': kind,
      });

  static Future<void> acceptCall(String callId) =>
      db.rpc('accept_call', params: {'p_call': callId});

  static Future<void> reschedule(String matchId, DateTime when, String kind) =>
      db.rpc('request_reschedule', params: {
        'p_match': matchId,
        'p_new_time': when.toUtc().toIso8601String(),
        'p_kind': kind,
      });

  // ---------- feed ----------
  static Future<List<Map<String, dynamic>>> feed({String? range, int? topic, DateTime? before}) async =>
      List<Map<String, dynamic>>.from(await db.rpc('get_feed', params: {
        'p_range': range,
        'p_topic': topic,
        'p_before': before?.toUtc().toIso8601String(),
        'p_limit': 30,
      }));

  static Future<void> post({required int topicId, required String kind, required String body}) =>
      db.from('posts').insert({'author_id': me, 'topic_id': topicId, 'kind': kind, 'body': body});

  static Future<void> react(String postId, bool on) => on
      ? db.from('reactions').upsert({'post_id': postId, 'user_id': me})
      : db.from('reactions').delete().eq('post_id', postId).eq('user_id', me);

  static Future<void> save(String postId, bool on) => on
      ? db.from('saves').upsert({'post_id': postId, 'user_id': me})
      : db.from('saves').delete().eq('post_id', postId).eq('user_id', me);

  static Future<List<Map<String, dynamic>>> comments(String postId) =>
      db.from('comments').select().eq('post_id', postId).order('created_at');

  static Future<void> comment(String postId, String body) =>
      db.from('comments').insert({'post_id': postId, 'author_id': me, 'body': body});

  // ---------- safety ----------
  static Future<void> block(String userId) => db.rpc('block_user', params: {'p_target': userId});

  static Future<void> report(String userId, String category, {String? details, String? matchId}) =>
      db.rpc('report_user', params: {
        'p_target': userId,
        'p_category': category,
        'p_details': details,
        'p_match': matchId,
      });

  // ---------- storage ----------
  static Future<String> photoUrl(String path) =>
      db.storage.from('photos').createSignedUrl(path, 60 * 60);
}
