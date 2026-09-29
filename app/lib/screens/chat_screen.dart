import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'call_screen.dart';
import 'profile_view_screen.dart';

/// Chat for one match: icebreaker, call scheduling (3-day window, 2 reschedules),
/// "Not feeling it", report/block, and number sharing once unlocked.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.match});
  final Map<String, dynamic> match;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  late Map<String, dynamic> _m = widget.match;
  List<Map<String, dynamic>> _calls = [];

  String get _matchId => _m['match_id'] as String;
  String get _otherId => _m['other_id'] as String;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await Api.myMatches();
    final calls = await Api.calls(_matchId);
    if (!mounted) return;
    setState(() {
      _m = all.firstWhere((x) => x['match_id'] == _matchId, orElse: () => _m);
      _calls = calls;
    });
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
      await _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
  }

  String _clean(Object e) => e.toString().replaceAll(RegExp(r'^.*?message: '), '').replaceAll(RegExp(r',.*$'), '');

  Future<void> _send([String? body]) async {
    final t = (body ?? _text.text).trim();
    if (t.isEmpty) return;
    _text.clear();
    await _guard(() => Api.send(_matchId, t));
  }

  Future<DateTime?> _pickTime() async {
    final now = DateTime.now();
    // Before the first call: by the deadline. After it: any time in the next month.
    final latest = _m['call_done'] == true
        ? now.add(const Duration(days: 30))
        : DateTime.parse(_m['call_deadline'] as String).toLocal();
    final d = await showDatePicker(context: context, firstDate: now, lastDate: latest.isAfter(now) ? latest : now, initialDate: now);
    if (d == null || !mounted) return null;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Future<String?> _pickKind() => showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(leading: const Icon(Icons.call), title: const Text('Voice call'), onTap: () => Navigator.pop(ctx, 'voice')),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Video call'),
              subtitle: const Text('Unlocks sharing phone numbers afterwards'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
          ]),
        ),
      );

  Future<void> _propose({bool reschedule = false}) async {
    final kind = await _pickKind();
    if (kind == null) return;
    final when = await _pickTime();
    if (when == null) return;
    await _guard(() => reschedule ? Api.reschedule(_matchId, when, kind) : Api.proposeCall(_matchId, when, kind));
  }

  Future<void> _menu(String action) async {
    switch (action) {
      case 'profile':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: _otherId)));
      case 'not_feeling_it':
        final ok = await _confirm('Not feeling it?', 'This ends the match politely. It never counts against you.');
        if (ok) {
          await Api.notFeelingIt(_matchId);
          if (mounted) Navigator.of(context).pop();
        }
      case 'block':
        if (await _confirm('Block?', 'They won\'t see you again and the match ends.')) {
          await Api.block(_otherId);
          if (mounted) Navigator.of(context).pop();
        }
      case 'report':
        final cat = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final c in const {
                'fake_profile': 'Fake profile',
                'harassment': 'Harassment',
                'scam': 'Scam or asking for money',
                'explicit': 'Explicit content',
                'underage': 'May be under 18',
                'threats': 'Threats or violence',
              }.entries)
                ListTile(title: Text(c.value), onTap: () => Navigator.pop(ctx, c.key)),
            ]),
          ),
        );
        if (cat != null) {
          await Api.report(_otherId, cat, matchId: _matchId);
          if (mounted) Navigator.of(context).pop();
        }
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
          ],
        ),
      ) ??
      false;

  Widget _callPanel() {
    final fmt = DateFormat('EEE h:mm a');
    final open = _calls.isEmpty ? null : _calls.first;
    final left = _m['reschedules_left'] as int? ?? 0;
    final done = _m['call_done'] == true;
    final h = hoursLeft(_m);
    final u = urgencyColors(h);

    if (done && open == null) {
      final video = _m['video_call_done'] == true;
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: B.okSoft, borderRadius: BorderRadius.circular(18)),
        child: Row(children: [
          Expanded(
            child: Text(
              _m['contact_unlocked'] == true
                  ? 'Call done ✓ · Phone numbers unlocked'
                  : video
                      ? 'Call done ✓ · One message each unlocks phone numbers'
                      : 'Call done ✓ · A video call unlocks phone numbers',
              style: TextStyle(fontWeight: FontWeight.w700, color: B.okInk),
            ),
          ),
          TextButton.icon(
            onPressed: _propose,
            icon: Icon(video ? Icons.call : Icons.videocam, size: 18),
            label: Text(video ? 'Call again' : 'Video call'),
          ),
        ]),
      );
    }

    const onDark = TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (open == null)
          Text('${timeLeftLabel(h)} to get a call in · $left reschedule${left == 1 ? '' : 's'} left', style: onDark)
        else
          Text('${open['kind'] == 'video' ? 'Video' : 'Voice'} call · '
              '${fmt.format(DateTime.parse(open['scheduled_for'] as String).toLocal())} · '
              '${open['status'] == 'accepted' ? 'confirmed' : 'waiting for a yes'}', style: onDark),
        if (!done) ...[
          const SizedBox(height: 10),
          DeadlineBar(
            fraction: h / 72,
            color: u.color == B.ink ? Colors.white : (u.color == B.urgent ? const Color(0xFFE5484D) : const Color(0xFFE0A24A)),
            track: const Color(0xFF3B4048),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (open == null)
            FilledButton.icon(onPressed: _propose, icon: const Icon(Icons.videocam, size: 18), label: const Text('Propose a call')),
          if (open != null && open['status'] == 'proposed' && open['proposed_by'] != Api.me)
            FilledButton(onPressed: () => _guard(() => Api.acceptCall(open['id'] as String)), child: const Text('Accept')),
          if (open != null && open['status'] == 'accepted')
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CallScreen(
                  callId: open['id'] as String,
                  kind: open['kind'] as String,
                  matchId: _matchId,
                  otherId: _otherId,
                ),
              )).then((_) => _reload()),
              icon: const Icon(Icons.call, size: 18),
              label: const Text('Join'),
            ),
          // Not confirmed yet: either person can suggest another time for free.
          if (open != null && open['status'] == 'proposed')
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: B.onPanelMuted, width: 1.5)),
              onPressed: _propose,
              child: Text(open['proposed_by'] == Api.me ? 'Change time' : 'Suggest another time'),
            ),
          // Confirmed: moving it uses one of the 2 shared reschedules.
          if (open != null && open['status'] == 'accepted' && left > 0)
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: B.onPanelMuted, width: 1.5)),
              onPressed: () => _propose(reschedule: true),
              child: Text('Reschedule ($left left)'),
            ),
        ]),
      ]),
    );
  }

  Future<void> _shareNumber() async {
    final ctrl = TextEditingController();
    final number = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: B.card,
        title: const Text('Share your number'),
        content: TextField(controller: ctrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: '403 555 0100')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (number != null && number.isNotEmpty) _send('My number: $number');
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = _m['contact_unlocked'] == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(_m['other_name'] as String),
        actions: [
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('View profile')),
              PopupMenuItem(value: 'not_feeling_it', child: Text('Not feeling it')),
              PopupMenuItem(value: 'report', child: Text('Report')),
              PopupMenuItem(value: 'block', child: Text('Block')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        _callPanel(),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: Api.messages(_matchId),
            builder: (context, snap) {
              final msgs = snap.data ?? [];
              return ListView(
                reverse: true,
                padding: const EdgeInsets.all(12),
                children: [
                  for (final msg in msgs.reversed) _bubble(msg),
                  if (_m['icebreaker'] != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: B.cardBox(),
                      child: Text.rich(TextSpan(children: [
                        const TextSpan(text: 'Icebreaker: ', style: TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(text: _m['icebreaker'] as String),
                      ]), style: TextStyle(color: B.ink2)),
                    ),
                ],
              );
            },
          ),
        ),
        if (unlocked)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: B.okInk, backgroundColor: B.okSoft, side: BorderSide(color: B.ok, width: 1.5)),
              onPressed: _shareNumber,
              icon: const Icon(Icons.phone),
              label: const Text('Share my number'),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: 'Message'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Send',
                style: IconButton.styleFrom(backgroundColor: B.accent, minimumSize: const Size(48, 48)),
                onPressed: _send,
                icon: const Icon(Icons.arrow_forward, color: Colors.white),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> msg) {
    final mine = msg['sender_id'] == Api.me;
    final blocked = msg['status'] == 'blocked';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: blocked ? B.urgentSoft : (mine ? B.panel : B.card),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 6),
            bottomRight: Radius.circular(mine ? 6 : 18),
          ),
          border: blocked ? Border.all(color: B.urgent) : null,
          boxShadow: mine || blocked ? null : B.shadow,
        ),
        child: Text(
          blocked ? 'Not sent: contact info unlocks after a video call and one message from each of you.' : msg['body'] as String,
          style: TextStyle(fontSize: 15, height: 1.35, color: blocked ? B.urgent : (mine ? Colors.white : B.ink)),
        ),
      ),
    );
  }
}
