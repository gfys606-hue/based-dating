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

  /// Put a new picture into an existing slot (keeps the slot filled the whole time,
  /// so the account never blips to "paused"), or into an empty slot.
  static Future<Map<String, dynamic>> replacePhoto(int position, Uint8List bytes) async {
    final path = '$me/p${position}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await db.storage.from('photos').uploadBinary(path, bytes);
    final existing = await db.from('photos').select().eq('user_id', me).eq('position', position).maybeSingle();
    Map<String, dynamic> row;
    if (existing == null) {
      row = await db.from('photos').insert({'user_id': me, 'storage_path': path, 'position': position}).select().single();
    } else {
      row = await db.from('photos').update({'storage_path': path}).eq('id', existing['id']).select().single();
      try {
        await db.storage.from('photos').remove([existing['storage_path'] as String]);
      } catch (_) {}
    }
    final res = await db.functions.invoke('photo-check', body: {'type': 'photo', 'photo_id': row['id']});
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Delete one of photos 4–6 (1–3 can only be replaced).
  static Future<void> deletePhoto(String photoId) async {
    final path = await db.rpc('delete_photo', params: {'p_photo': photoId}) as String?;
    if (path != null) {
      try {
        await db.storage.from('photos').remove([path]);
      } catch (_) {}
    }
  }

  /// New order for all photos (first = slot 1). Re-checks any photo that moved into slots 1–3.
  static Future<void> reorderPhotos(List<String> ids) async {
    final recheck = await db.rpc('reorder_photos', params: {'p_ids': ids}) as List?;
    for (final id in recheck ?? const []) {
      await db.functions.invoke('photo-check', body: {'type': 'photo', 'photo_id': id});
    }
  }

  static Future<Set<int>> myTopicIds() async {
    final rows = await db.from('user_topics').select('topic_id').eq('user_id', me);
    return {for (final r in rows) r['topic_id'] as int};
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
      .order('created_at', ascending: true);

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

  // ---------- notices (nudges, missed calls, blocked messages, expiries) ----------
  static Future<List<Map<String, dynamic>>> unreadNotices() async => List<Map<String, dynamic>>.from(await db
      .from('notifications')
      .select()
      .eq('user_id', me)
      .eq('read', false)
      .order('created_at', ascending: false)
      .limit(20));

  static Future<void> markNoticesRead(List<int> ids) =>
      db.from('notifications').update({'read': true}).inFilter('id', ids);

  // ---------- self-expression: Unedited voice, stance, (Lately comes with the profile) ----------
  static Future<Map<String, dynamic>> drawVoiceQuestion() async =>
      Map<String, dynamic>.from(await db.rpc('draw_voice_question') as Map);

  /// Upload the one take and attach it to the question you were given.
  static Future<void> saveVoiceAnswer(Uint8List bytes, int durationMs, {required bool webm}) async {
    final path = '$me/v_${DateTime.now().millisecondsSinceEpoch}.${webm ? 'webm' : 'm4a'}';
    await db.storage.from('voice').uploadBinary(path, bytes,
        fileOptions: FileOptions(contentType: webm ? 'audio/webm' : 'audio/mp4'));
    final old = await db.rpc('save_voice_answer', params: {'p_path': path, 'p_duration_ms': durationMs}) as String?;
    if (old != null) {
      try {
        await db.storage.from('voice').remove([old]);
      } catch (_) {}
    }
  }

  static Future<String> voiceUrl(String path) => db.storage.from('voice').createSignedUrl(path, 3600);

  static Future<void> setStance(String statement) => db.rpc('set_stance', params: {'p_statement': statement});

  /// verdict: 'agree', 'disagree', or '' to clear.
  static Future<void> reactStance(String userId, String verdict) =>
      db.rpc('react_stance', params: {'p_user': userId, 'p_verdict': verdict});

  // ---------- feed ----------
  static Future<List<Map<String, dynamic>>> feed({String? range, int? topic, DateTime? before}) async =>
      List<Map<String, dynamic>>.from(await db.rpc('get_feed', params: {
        'p_range': range,
        'p_topic': topic,
        'p_before': before?.toUtc().toIso8601String(),
        'p_limit': 30,
      }));

  // Steer the feed: weight -2 hide, -1 less, 0 neutral, 1 more, 2 lots more
  static Future<void> setTopicPref(int topicId, int weight) =>
      db.rpc('set_topic_pref', params: {'p_topic': topicId, 'p_weight': weight});
  static Future<void> setAuthorPref(String authorId, int weight) =>
      db.rpc('set_author_pref', params: {'p_author': authorId, 'p_weight': weight});
  static Future<Map<String, dynamic>> feedPrefs() async =>
      Map<String, dynamic>.from(await db.rpc('get_feed_prefs') as Map);
  static Future<void> resetFeed() => db.rpc('reset_feed');

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

  static Future<void> report(String userId, String category, {String? details, String? matchId, String? context}) =>
      db.rpc('report_user', params: {
        'p_target': userId,
        'p_category': category,
        'p_details': details,
        'p_match': matchId,
        'p_context': context,
      });

  // ---------- account ----------
  /// Permanently deletes the signed-in user's account, photos and data.
  static Future<void> deleteAccount() async {
    final uid = me;
    for (final bucket in const ['photos', 'selfies', 'media']) {
      try {
        final files = await db.storage.from(bucket).list(path: uid);
        if (files.isNotEmpty) {
          await db.storage.from(bucket).remove([for (final f in files) '$uid/${f.name}']);
        }
      } catch (_) {
        // Keep going: the account itself must still be deleted.
      }
    }
    await db.rpc('delete_my_account');
    await db.auth.signOut();
  }

  // ---------- storage ----------
  static Future<String> photoUrl(String path) =>
      db.storage.from('photos').createSignedUrl(path, 60 * 60);
}
