import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../services/plans_api.dart';
import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/live_chat.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// Who's In: the plan page. Who's in, what we need and who's bringing it, the group chat,
/// and afterwards, "did it happen?".
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key, required this.eventId, required this.title});
  final String eventId;
  final String title;
  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  Map<String, dynamic>? _plan;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await PlansApi.plan(widget.eventId);
      if (mounted) setState(() => _plan = p);
    } catch (e) {
      if (mounted) setState(() => _error = PlansApi.errorText(e));
    }
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
      _toast(PlansApi.errorText(e));
    }
  }

  Future<void> _addNeed() async {
    final c = TextEditingController();
    final item = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('What do we need?'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Boat, Truck, Tent, Ride from the NW'),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Add')),
        ],
      ),
    );
    if (item == null || item.trim().isEmpty) return;
    _run(() => PlansApi.addNeed(widget.eventId, item.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final p = _plan;
    final inPlan = p?['in'] == true;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          bottom: inPlan ? const TabBar(tabs: [Tab(text: 'Plan'), Tab(text: 'Chat')]) : null,
        ),
        body: p == null
            ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
            : inPlan
                ? TabBarView(children: [
                    _planTab(p),
                    LiveChat(
                      stream: PlansApi.messages(widget.eventId),
                      onSend: (b) => PlansApi.send(widget.eventId, b),
                      names: {
                        for (final m in List<Map<String, dynamic>>.from(
                            ((p['people'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map))))
                          m['user_id'] as String: m['name'] as String
                      },
                      showNames: true,
                      hint: 'Message everyone who\'s in',
                    ),
                  ])
                : _planTab(p),
      ),
    );
  }

  Widget _planTab(Map<String, dynamic> p) {
    final inPlan = p['in'] == true;
    final going = p['my_rsvp'] == 'going' || p['mine'] == true;
    final started = p['started'] == true;
    final at = DateTime.parse(p['starts_at'] as String).toLocal();
    final needs = List<Map<String, dynamic>>.from(((p['needs'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final people = List<Map<String, dynamic>>.from(((p['people'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          Text(DateFormat('EEEE, MMM d · h:mm a').format(at), style: TextStyle(color: B.goldInk, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('Hosted by ${p['mine'] == true ? 'you' : p['host']}', style: TextStyle(color: B.muted)),
          const SizedBox(height: 14),

          if (p['happened'] == true)
            _banner(Icons.verified_outlined, 'It happened. Nice.')
          else if (started && going) ...[
            _banner(Icons.help_outline, p['my_happened'] == null ? 'Did it happen?' : 'Thanks for confirming.'),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _choice('Yes, it happened', p['my_happened'] == true,
                    () => _run(() => PlansApi.confirmHappened(widget.eventId, true))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _choice('It didn\'t', p['my_happened'] == false,
                    () => _run(() => PlansApi.confirmHappened(widget.eventId, false))),
              ),
            ]),
            const SizedBox(height: 14),
          ],

          if (p['mine'] != true && !started)
            Row(children: [
              Expanded(
                child: _choice('I\'m in', p['my_rsvp'] == 'going', () => _run(() =>
                    SocialApi.rsvp(widget.eventId, p['my_rsvp'] == 'going' ? 'none' : 'going'))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _choice('Maybe', p['my_rsvp'] == 'maybe', () => _run(() =>
                    SocialApi.rsvp(widget.eventId, p['my_rsvp'] == 'maybe' ? 'none' : 'maybe'))),
              ),
            ]),
          const SizedBox(height: 18),

          // What we need
          Row(children: [
            const Expanded(child: SectionLabel('What we need')),
            if (inPlan && !started) TextButton.icon(onPressed: _addNeed, icon: const Icon(Icons.add, size: 18), label: const Text('Add')),
          ]),
          if (needs.isEmpty)
            Text(inPlan ? 'Nothing yet. Add gear, rides or food people can claim.' : 'Nothing listed yet.',
                style: TextStyle(color: B.muted, fontSize: 13)),
          for (final n in needs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(n['claimed_by'] == null ? Icons.radio_button_unchecked : Icons.check_circle,
                  color: n['claimed_by'] == null ? B.muted : B.goldInk),
              title: Text(n['item'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(n['claimed_by'] == null ? 'Still needed' : '${n['mine'] == true ? 'You\'re' : '${n['claimed_by']} is'} bringing it'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (going && !started && n['claimed_by'] == null)
                  TextButton(
                    onPressed: () => _run(() => PlansApi.claimNeed(n['id'] as String, true), ok: 'Thanks. You\'re bringing it.'),
                    child: const Text('I\'ll bring it'),
                  ),
                if (n['mine'] == true && !started)
                  TextButton(onPressed: () => _run(() => PlansApi.claimNeed(n['id'] as String, false)), child: const Text('Can\'t now')),
                if (n['can_remove'] == true && !started)
                  IconButton(
                    tooltip: 'Remove',
                    icon: Icon(Icons.close, size: 18, color: B.muted),
                    onPressed: () => _run(() => PlansApi.removeNeed(n['id'] as String)),
                  ),
              ]),
            ),
          const SizedBox(height: 18),

          // Who's in
          const SectionLabel('Who\'s in'),
          const SizedBox(height: 6),
          if (!inPlan) Text('Say you\'re in to see who\'s coming and join the chat.', style: TextStyle(color: B.muted, fontSize: 13)),
          for (final m in people)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Avatar(path: m['photo'] as String?, size: 38),
              title: Text(m['user_id'] == Api.me ? '${m['name']} (you)' : m['name'] as String),
              subtitle: Text(switch (m['rsvp']) { 'host' => 'Host', 'going' => 'In', _ => 'Maybe' }),
              onTap: m['user_id'] == Api.me
                  ? null
                  : () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: m['user_id'] as String))),
            ),
        ],
      ),
    );
  }

  Widget _banner(IconData icon, String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: B.cardBox(border: B.gold),
        child: Row(children: [
          Icon(icon, color: B.goldInk),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );

  Widget _choice(String label, bool on, VoidCallback onTap) =>
      on ? FilledButton(onPressed: onTap, child: Text(label)) : OutlinedButton(onPressed: onTap, child: Text(label));
}
