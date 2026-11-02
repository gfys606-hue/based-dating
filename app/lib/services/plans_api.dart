import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// Who's In (supabase/migrations/20261101000056_whos_in.sql): the plan page for any plan —
/// what we need and who's bringing it, a group chat, and "did it happen?" afterwards.
class PlansApi {
  PlansApi._();
  static final _db = Api.db;

  static String errorText(Object e) =>
      e is PostgrestException ? e.message : 'Something went wrong. Try again.';

  /// {event_id, title, starts_at, host, mine, my_rsvp, in, started, needs, people, my_happened, happened}
  static Future<Map<String, dynamic>> plan(String eventId) async =>
      Map<String, dynamic>.from(await _db.rpc('get_plan', params: {'p_event': eventId}) as Map);

  static Future<void> addNeed(String eventId, String item) =>
      _db.rpc('add_plan_need', params: {'p_event': eventId, 'p_item': item});

  static Future<void> removeNeed(String needId) => _db.rpc('remove_plan_need', params: {'p_need': needId});

  /// "I'll bring it" (or take it back).
  static Future<void> claimNeed(String needId, bool claim) =>
      _db.rpc('claim_plan_need', params: {'p_need': needId, 'p_claim': claim});

  static Future<void> confirmHappened(String eventId, bool happened) =>
      _db.rpc('confirm_plan_happened', params: {'p_event': eventId, 'p_happened': happened});

  static Stream<List<Map<String, dynamic>>> messages(String eventId) => _db
      .from('event_messages')
      .stream(primaryKey: ['id'])
      .eq('event_id', eventId)
      .order('created_at', ascending: true);

  static Future<void> send(String eventId, String body) =>
      _db.from('event_messages').insert({'event_id': eventId, 'sender_id': Api.me, 'body': body});
}
