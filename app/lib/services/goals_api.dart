import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// Goals and challenges (supabase/migrations/20261101000055_goals.sql): herd or personal goals,
/// habits (N times a week) or milestones, ready-made challenges, positive-only accountability.
class GoalsApi {
  GoalsApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static String errorText(Object e) =>
      e is PostgrestException ? e.message : 'Something went wrong. Try again.';

  /// circleId null = every goal you're in; otherwise the herd's goals.
  static Future<List<Map<String, dynamic>>> goals({String? circleId}) async =>
      _rows(await _db.rpc('get_goals', params: {'p_circle': circleId}));

  static Future<List<Map<String, dynamic>>> challenges() async => _rows(await _db.rpc('get_challenges'));

  static Future<String> create({
    String? circleId,
    required String title,
    required String kind, // 'habit' | 'milestones'
    int? perWeek,
    required DateTime endsOn,
    List<String> milestones = const [],
  }) async =>
      await _db.rpc('create_goal', params: {
        'p_circle': circleId,
        'p_title': title,
        'p_kind': kind,
        'p_per_week': perWeek,
        'p_ends_on': endsOn.toIso8601String().substring(0, 10),
        'p_milestones': milestones,
      }) as String;

  static Future<String> startChallenge(String slug, {String? circleId}) async =>
      await _db.rpc('start_challenge', params: {'p_slug': slug, 'p_circle': circleId}) as String;

  static Future<void> join(String goalId, bool join) =>
      _db.rpc('join_goal', params: {'p_goal': goalId, 'p_join': join});

  /// Returns your check-ins so far this week.
  static Future<int> checkIn(String goalId, bool done) async =>
      (await _db.rpc('goal_check_in', params: {'p_goal': goalId, 'p_done': done}) as num).toInt();

  static Future<void> setMilestone(String milestoneId, bool done) =>
      _db.rpc('set_goal_milestone', params: {'p_milestone': milestoneId, 'p_done': done});
}
