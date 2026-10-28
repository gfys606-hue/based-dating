import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// The idea feed (supabase/migrations/20261027000049_idea_feed.sql):
/// short ideas routed to the people they fit, "same idea" nudges, I'm in / Let's talk chats,
/// and turning an idea into a group (a Herd).
class IdeasApi {
  IdeasApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  /// The server's plain-English reason when something is refused.
  static String errorText(Object e) =>
      e is PostgrestException ? e.message : 'Something went wrong. Try again.';

  static Future<List<Map<String, dynamic>>> feed({DateTime? before}) async =>
      _rows(await _db.rpc('get_ideas', params: {'p_before': before?.toUtc().toIso8601String(), 'p_limit': 30}));

  /// People whose ideas are close to one of yours.
  static Future<List<Map<String, dynamic>>> sameIdeas() async => _rows(await _db.rpc('get_same_ideas'));

  static Future<String> post(String body) async => await _db.rpc('post_idea', params: {'p_body': body}) as String;

  /// live | closed | removed
  static Future<void> setStatus(String ideaId, String status) =>
      _db.rpc('set_idea_status', params: {'p_idea': ideaId, 'p_status': status});

  /// Hide an idea from your feed, or "Not now" on a same-idea nudge.
  static Future<void> dismiss(String ideaId) => _db.rpc('dismiss_idea', params: {'p_idea': ideaId});

  /// kind: 'in' or 'talk'. Returns the chat with the author.
  static Future<String> respond(String ideaId, String kind) async =>
      await _db.rpc('respond_to_idea', params: {'p_idea': ideaId, 'p_kind': kind}) as String;

  static Future<void> withdraw(String ideaId) => _db.rpc('withdraw_idea_response', params: {'p_idea': ideaId});

  /// Start a Herd for the idea; everyone who said "I'm in" gets an invite. Returns the herd id.
  static Future<String> toGroup(String ideaId, String name) async =>
      await _db.rpc('idea_to_group', params: {'p_idea': ideaId, 'p_name': name}) as String;

  static Future<void> inviteToGroup(String ideaId, String userId) =>
      _db.rpc('invite_to_idea_group', params: {'p_idea': ideaId, 'p_user': userId});

  static Future<List<Map<String, dynamic>>> threads() async => _rows(await _db.rpc('get_my_idea_threads'));

  static Stream<List<Map<String, dynamic>>> messages(String threadId) => _db
      .from('idea_messages')
      .stream(primaryKey: ['id'])
      .eq('thread_id', threadId)
      .order('created_at', ascending: true);

  static Future<void> send(String threadId, String body) =>
      _db.from('idea_messages').insert({'thread_id': threadId, 'sender_id': Api.me, 'body': body});
}
