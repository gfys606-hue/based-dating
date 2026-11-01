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

  // ---------- Idea cards (supabase/migrations/20261101000050_idea_cards.sql) ----------
  // Short ideas from books and thinkers, summarized in our own words and credited, picked for you
  // (up to 3 a day). Saving one is how you find people who think alike.

  /// Today's picks for you.
  static Future<List<Map<String, dynamic>>> cards() async => _rows(await _db.rpc('get_idea_cards'));

  static Future<List<Map<String, dynamic>>> savedCards() async => _rows(await _db.rpc('get_saved_cards'));

  static Future<void> saveCard(String cardId, bool save) =>
      _db.rpc('save_idea_card', params: {'p_card': cardId, 'p_save': save});

  /// "Not for me": drops it from today's picks and it won't come back.
  static Future<void> hideCard(String cardId) => _db.rpc('hide_idea_card', params: {'p_card': cardId});

  /// People who saved the same cards you did.
  static Future<List<Map<String, dynamic>>> cardKindred() async => _rows(await _db.rpc('get_card_kindred'));

  static Future<void> dismissCardKindred(String userId) =>
      _db.rpc('dismiss_card_kindred', params: {'p_user': userId});

  // ---------- Reactions + conversations (supabase/migrations/20261101000052_idea_reactions.sql) ----------
  // kind is 'idea' (a person's idea) or 'card' (a Based pick).

  /// reaction: 'back' | 'push' | null (take it back). Reason, note and tag are optional.
  /// Returns {thread_id, backs_left}; thread_id is set when "I'd join" opened a chat with the author.
  static Future<Map<String, dynamic>> react(String kind, String id, String? reaction,
      {String? reason, String? note, String? tag}) async {
    final res = await _db.rpc('react_to_idea', params: {
      'p_kind': kind,
      'p_id': id,
      'p_reaction': reaction,
      'p_reason': reason,
      'p_note': note,
      'p_tag': tag,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  static Future<int> backsLeft() async => (await _db.rpc('my_backs_left') as num).toInt();

  /// My reaction on each, whether I'm in its conversation, and (on my own ideas) the private
  /// temperature and who reacted and why.
  static Future<Map<String, Map<String, dynamic>>> reactions(String kind, List<String> ids) async {
    if (ids.isEmpty) return {};
    final rows = _rows(await _db.rpc('get_idea_reactions', params: {'p_kind': kind, 'p_ids': ids}));
    return {for (final r in rows) r['target_id'] as String: r};
  }

  /// {joined, is_author, posts: [...], members: [...] (only when joined)}
  static Future<Map<String, dynamic>> convo(String kind, String id) async =>
      Map<String, dynamic>.from(await _db.rpc('get_idea_convo', params: {'p_kind': kind, 'p_id': id}) as Map);

  static Future<void> joinConvo(String kind, String id) =>
      _db.rpc('join_idea_convo', params: {'p_kind': kind, 'p_id': id});

  static Future<void> leaveConvo(String kind, String id) =>
      _db.rpc('leave_idea_convo', params: {'p_kind': kind, 'p_id': id});

  static Future<void> comment(String kind, String id, String body) =>
      _db.rpc('post_idea_convo', params: {'p_kind': kind, 'p_id': id, 'p_body': body});

  static Future<void> removeComment(String postId) => _db.rpc('remove_idea_convo_post', params: {'p_post': postId});

  /// On your own idea: open a private chat with someone who reacted or commented.
  static Future<String> authorTalk(String ideaId, String userId) async =>
      await _db.rpc('idea_author_talk', params: {'p_idea': ideaId, 'p_user': userId}) as String;
}
