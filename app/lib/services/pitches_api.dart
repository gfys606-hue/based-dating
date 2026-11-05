import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// Pitch cards (supabase/migrations/20261105000058_pitch_cards.sql): the idea, its stage, the ask
/// and who you are; routed to members who fit the ask. "Let's talk" opens a private chat. No public counts.
class PitchesApi {
  PitchesApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static String errorText(Object e) => e is PostgrestException ? e.message : 'Something went wrong. Try again.';

  /// Stages and asks: {stages: [{tag, label}], asks: [{tag, label}]}
  static Map<String, dynamic>? _options;
  static Future<Map<String, dynamic>> options() async =>
      _options ??= Map<String, dynamic>.from(await _db.rpc('pitch_options') as Map);

  /// view: 'for_you' (fits you) or 'all' (every pitch in your city). ask: only pitches with this ask.
  static Future<List<Map<String, dynamic>>> pitches({String view = 'for_you', String? ask}) async =>
      _rows(await _db.rpc('get_pitches', params: {'p_view': view, 'p_ask': ask, 'p_limit': 40}));

  static Future<List<Map<String, dynamic>>> mine() async => _rows(await _db.rpc('get_my_pitches'));

  static Future<String> post({
    required String idea,
    required String stage,
    required List<String> asks,
    required String about,
    String? askNote,
  }) async =>
      await _db.rpc('post_pitch', params: {
        'p_idea': idea,
        'p_stage': stage,
        'p_asks': asks,
        'p_about': about,
        'p_ask_note': askNote,
      }) as String;

  static Future<void> edit(
    String pitchId, {
    required String idea,
    required String stage,
    required List<String> asks,
    required String about,
    String? askNote,
  }) =>
      _db.rpc('edit_pitch', params: {
        'p_pitch': pitchId,
        'p_idea': idea,
        'p_stage': stage,
        'p_asks': asks,
        'p_about': about,
        'p_ask_note': askNote,
      });

  /// live | closed | removed
  static Future<void> setStatus(String pitchId, String status) =>
      _db.rpc('set_pitch_status', params: {'p_pitch': pitchId, 'p_status': status});

  static Future<void> hide(String pitchId) => _db.rpc('hide_pitch', params: {'p_pitch': pitchId});

  /// Opens (or reuses) a private chat with the author. Returns the chat id.
  static Future<String> talk(String pitchId) async =>
      await _db.rpc('talk_about_pitch', params: {'p_pitch': pitchId}) as String;

  static Future<List<Map<String, dynamic>>> threads() async => _rows(await _db.rpc('get_my_pitch_threads'));

  static Stream<List<Map<String, dynamic>>> messages(String threadId) => _db
      .from('pitch_messages')
      .stream(primaryKey: ['id'])
      .eq('thread_id', threadId)
      .order('created_at', ascending: true);

  static Future<void> send(String threadId, String body) =>
      _db.from('pitch_messages').insert({'thread_id': threadId, 'sender_id': Api.me, 'body': body});
}
