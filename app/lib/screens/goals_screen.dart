import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/goals_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Goals & challenges: everything you're working toward, alone or with your herds.
class GoalsScreen extends StatelessWidget {
  const GoalsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Goals & challenges')),
        body: const GoalsList(),
      );
}

/// The goals list. With [circleId] it's a herd's goals (the herd's Goals tab); without, it's yours.
class GoalsList extends StatefulWidget {
  const GoalsList({super.key, this.circleId});
  final String? circleId;
  @override
  State<GoalsList> createState() => _GoalsListState();
}

class _GoalsListState extends State<GoalsList> {
  bool _loading = true;
  List<Map<String, dynamic>> _goals = [];

  bool get _herd => widget.circleId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _goals = await GoalsApi.goals(circleId: widget.circleId);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _run(Future<void> Function() f, {String? ok}) async {
    try {
      await f();
      if (ok != null) _toast(ok);
      await _load();
    } catch (e) {
      _toast(GoalsApi.errorText(e));
    }
  }

  Future<void> _newGoal() async {
    final made = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: B.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _NewGoalSheet(circleId: widget.circleId),
    );
    if (made == true) {
      _toast(_herd ? 'Goal started. Your herd got a heads-up.' : 'Goal started.');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            _herd
                ? 'Give the herd something to do together. Only people in a goal see each other\'s progress on it.'
                : 'Don\'t just talk about doing something, do it. Start your own goal, pick a challenge, or join one in your herds.',
            style: TextStyle(color: B.ink2, fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _newGoal,
                icon: const Icon(Icons.flag_outlined, size: 18),
                label: const Text('New goal'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final started = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => ChallengesScreen(circleId: widget.circleId)),
                  );
                  if (started == true) _load();
                },
                icon: const Icon(Icons.emoji_events_outlined, size: 18),
                label: const Text('Challenges'),
              ),
            ),
          ]),
          const SizedBox(height: 18),
          if (_goals.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Text(_herd ? 'No goals in this herd yet.' : 'No goals yet.',
                  textAlign: TextAlign.center, style: TextStyle(color: B.muted)),
            ),
          for (final g in _goals) ...[
            _GoalCard(
              goal: g,
              showHerd: !_herd,
              onJoin: (join) => _run(() => GoalsApi.join(g['goal_id'] as String, join),
                  ok: join ? 'You\'re in.' : (g['circle_id'] == null ? 'Goal ended.' : 'You\'re out of this one.')),
              onCheckIn: (done) => _run(() async {
                final n = await GoalsApi.checkIn(g['goal_id'] as String, done);
                if (done) _toast('Checked in. $n of ${g['per_week']} this week.');
              }),
              onMilestone: (id, done) => _run(() => GoalsApi.setMilestone(id, done)),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.showHerd,
    required this.onJoin,
    required this.onCheckIn,
    required this.onMilestone,
  });
  final Map<String, dynamic> goal;
  final bool showHerd;
  final void Function(bool join) onJoin;
  final void Function(bool done) onCheckIn;
  final void Function(String id, bool done) onMilestone;

  @override
  Widget build(BuildContext context) {
    final joined = goal['joined'] == true;
    final active = goal['status'] == 'active';
    final habit = goal['kind'] == 'habit';
    final members = List<Map<String, dynamic>>.from(((goal['members'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final milestones =
        List<Map<String, dynamic>>.from(((goal['milestones'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final perWeek = (goal['per_week'] as num?)?.toInt() ?? 0;
    final myWeek = (goal['my_week'] as num?)?.toInt() ?? 0;
    final daysLeft = (goal['days_left'] as num?)?.toInt() ?? 0;
    final done = milestones.where((m) => m['done'] == true).length;
    final status = switch (goal['status']) {
      'done' => 'Complete',
      'ended' => 'Ended ${DateFormat('MMM d').format(DateTime.parse(goal['ends_on'] as String))}',
      _ => daysLeft == 1 ? '1 day left' : '$daysLeft days left',
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: B.cardBox(border: goal['status'] == 'done' ? B.gold : null),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(habit ? Icons.repeat : Icons.flag_outlined, size: 18, color: B.goldInk),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              [
                habit ? '$perWeek a week' : '$done of ${milestones.length} done',
                status,
                if (showHerd && goal['circle_name'] != null) goal['circle_name'] as String,
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: B.goldInk, fontWeight: FontWeight.w700),
            ),
          ),
          if (joined && active)
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: Icon(Icons.more_horiz, color: B.muted),
              onSelected: (_) => onJoin(false),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'leave', child: Text(goal['circle_id'] == null ? 'End this goal' : 'Leave this goal')),
              ],
            ),
        ]),
        const SizedBox(height: 6),
        Text(goal['title'] as String, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.3)),
        const SizedBox(height: 10),

        // habit: this week, for everyone in the goal
        if (habit) ...[
          for (final m in members)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Avatar(path: m['photo'] as String?, size: 26),
                const SizedBox(width: 8),
                SizedBox(width: 90, child: Text(m['name'] as String, overflow: TextOverflow.ellipsis)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: perWeek == 0 ? 0 : (((m['week'] as num?) ?? 0) / perWeek).clamp(0, 1).toDouble(),
                      minHeight: 8,
                      backgroundColor: B.fill,
                      color: B.gold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${m['week']}/$perWeek', style: TextStyle(fontSize: 12, color: B.muted)),
              ]),
            ),
          if (joined && active)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: goal['checked_today'] == true
                  ? Row(children: [
                      Icon(Icons.check_circle, color: B.goldInk, size: 20),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Done today · $myWeek of $perWeek this week')),
                      TextButton(onPressed: () => onCheckIn(false), child: const Text('Undo')),
                    ])
                  : FilledButton.icon(
                      onPressed: () => onCheckIn(true),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text('Did it today · $myWeek of $perWeek this week'),
                    ),
            ),
        ],

        // milestones: tick them off
        if (!habit)
          for (final m in milestones)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: m['done'] == true,
              onChanged: joined && goal['status'] != 'ended' ? (v) => onMilestone(m['id'] as String, v == true) : null,
              title: Text(m['title'] as String,
                  style: TextStyle(decoration: m['done'] == true ? TextDecoration.lineThrough : null)),
              subtitle: m['done'] == true && m['done_by'] != null ? Text('by ${m['done_by']}') : null,
            ),
        if (!habit && members.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('In it: ${members.map((m) => m['name']).join(', ')}', style: TextStyle(fontSize: 12.5, color: B.muted)),
          ),

        if (!joined && active)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton(onPressed: () => onJoin(true), child: const Text('I\'m in')),
          ),
      ]),
    );
  }
}

class _NewGoalSheet extends StatefulWidget {
  const _NewGoalSheet({this.circleId});
  final String? circleId;
  @override
  State<_NewGoalSheet> createState() => _NewGoalSheetState();
}

class _NewGoalSheetState extends State<_NewGoalSheet> {
  final _title = TextEditingController();
  final _milestones = TextEditingController();
  String _kind = 'habit';
  int _perWeek = 3;
  int _weeks = 12;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _milestones.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await GoalsApi.create(
        circleId: widget.circleId,
        title: _title.text.trim(),
        kind: _kind,
        perWeek: _kind == 'habit' ? _perWeek : null,
        endsOn: DateTime.now().add(Duration(days: _weeks * 7)),
        milestones: _milestones.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = GoalsApi.errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.circleId == null ? 'New goal' : 'New herd goal', style: B.heading(22)),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'What\'s the goal?', hintText: 'e.g. Morning lifts, Launch the welding app'),
          ),
          const SizedBox(height: 4),
          Segmented(
            options: const ['A habit', 'Milestones'],
            index: _kind == 'habit' ? 0 : 1,
            onChanged: (i) => setState(() => _kind = i == 0 ? 'habit' : 'milestones'),
          ),
          const SizedBox(height: 14),
          if (_kind == 'habit')
            Row(children: [
              const Expanded(child: Text('Times a week')),
              IconButton(onPressed: _perWeek > 1 ? () => setState(() => _perWeek--) : null, icon: const Icon(Icons.remove)),
              Text('$_perWeek', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              IconButton(onPressed: _perWeek < 14 ? () => setState(() => _perWeek++) : null, icon: const Icon(Icons.add)),
            ])
          else
            TextField(
              controller: _milestones,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Milestones, one per line',
                hintText: 'Idea\nFirst customer\nWebsite up\nFirst \$1,000',
              ),
            ),
          Row(children: [
            const Expanded(child: Text('For how long')),
            IconButton(onPressed: _weeks > 1 ? () => setState(() => _weeks--) : null, icon: const Icon(Icons.remove)),
            Text('$_weeks week${_weeks == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            IconButton(onPressed: _weeks < 52 ? () => setState(() => _weeks++) : null, icon: const Icon(Icons.add)),
          ]),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Starting…' : 'Start it'),
          ),
        ]),
      ),
    );
  }
}

/// Ready-made challenges anyone can start, alone or with a herd.
class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({super.key, this.circleId});
  final String? circleId;
  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

class _ChallengesScreenState extends State<ChallengesScreen> {
  List<Map<String, dynamic>>? _list;

  @override
  void initState() {
    super.initState();
    GoalsApi.challenges().then((l) {
      if (mounted) setState(() => _list = l);
    }).catchError((_) {
      if (mounted) setState(() => _list = []);
    });
  }

  Future<void> _start(Map<String, dynamic> c) async {
    try {
      await GoalsApi.startChallenge(c['slug'] as String, circleId: widget.circleId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(widget.circleId == null ? 'Challenge started.' : 'Challenge started. Your herd got a heads-up.'),
      ));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(GoalsApi.errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: Text(widget.circleId == null ? 'Challenges' : 'Herd challenges')),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                for (final c in list) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: B.cardBox(),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        c['kind'] == 'habit'
                            ? '${c['per_week']} a week · ${c['days']} days'
                            : '${(c['milestones'] as List).length} milestones · ${c['days']} days',
                        style: TextStyle(fontSize: 12, color: B.goldInk, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(c['title'] as String, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(c['blurb'] as String, style: TextStyle(color: B.ink2, height: 1.4)),
                      const SizedBox(height: 10),
                      FilledButton(
                        onPressed: () => _start(c),
                        child: Text(widget.circleId == null ? 'Start it' : 'Start it with the herd'),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}
