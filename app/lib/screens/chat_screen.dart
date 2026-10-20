import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/venue_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import '../widgets/voice_note.dart';
import 'profile_view_screen.dart';

/// Chat for one match: icebreaker, the voice-note swap (texting pauses on day 4 until you've both
/// sent one), "Not feeling it", report/block, and number sharing once the swap is done.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.match});
  final Map<String, dynamic> match;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  late Map<String, dynamic> _m = widget.match;
  bool _reloading = false;

  String get _matchId => _m['match_id'] as String;
  String get _otherId => _m['other_id'] as String;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await Api.myMatches();
    if (!mounted) return;
    setState(() => _m = all.firstWhere((x) => x['match_id'] == _matchId, orElse: () => _m));
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

  Future<void> _menu(String action) async {
    switch (action) {
      case 'profile':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: _otherId)));
      case 'venue':
        await _suggestVenue();
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

  /// Partner venues nearby: public, staffed places that work with Based. A safe first meet.
  Future<void> _suggestVenue() async {
    final list = await VenueApi.partners().catchError((_) => <Map<String, dynamic>>[]);
    if (!mounted) return;
    final pick = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Text('Somewhere good to meet', style: B.heading(22)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Partner venues: public, staffed, and they know Based.', style: TextStyle(color: B.muted, fontSize: 13)),
          ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('No partner venues near you yet.', style: TextStyle(color: B.muted)),
            ),
          for (final v in list.take(6))
            ListTile(
              leading: Icon(Icons.verified_outlined, color: B.goldInk),
              title: Text(v['name'] as String),
              subtitle: Text('${(v['distance_km'] as num).toStringAsFixed(1)} km${v['address'] == null ? '' : ' · ${v['address']}'}'),
              onTap: () => Navigator.pop(ctx, v),
            ),
        ]),
      ),
    );
    if (pick == null) return;
    final where = pick['address'] == null ? '${pick['name']}' : '${pick['name']} (${pick['address']})';
    await _guard(() => Api.send(_matchId, 'How about meeting at $where?'));
  }

  Future<void> _voice() async {
    final sent = await recordVoiceNote(context, _matchId);
    if (sent) await _reload();
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

  bool get _locked => _m['text_locked'] == true;

  /// Where the swap stands, and the countdown to texting pausing.
  Widget _voicePanel() {
    final swapped = _m['voice_swapped'] == true || _m['call_done'] == true;
    if (swapped) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: B.okSoft, borderRadius: BorderRadius.circular(4)),
        child: Text(
          _m['contact_unlocked'] == true ? 'Voice notes swapped ✓ · Phone numbers unlocked' : 'Voice notes swapped ✓',
          style: TextStyle(fontWeight: FontWeight.w700, color: B.okInk),
        ),
      );
    }
    final mine = _m['voice_mine'] == true;
    final theirs = _m['voice_theirs'] == true;
    final h = hoursLeft(_m);
    final name = _m['other_name'] as String;
    final status = mine
        ? 'Your voice note is sent. Waiting on $name\'s.'
        : theirs
            ? '$name sent a voice note. Send one back to unlock numbers.'
            : 'Swap voice notes to unlock numbers.';
    final when = _locked
        ? 'Texting is paused until you\'ve both sent one.'
        : h > 24
            ? 'Optional for now. Texting pauses in ${timeLeftLabel(h)} if you haven\'t both sent one.'
            : 'Texting pauses in ${timeLeftLabel(h)} until you\'ve both sent one.';
    const onDark = TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(status, style: onDark),
        const SizedBox(height: 4),
        Text(when, style: const TextStyle(color: B.onPanelMuted, fontSize: 13, height: 1.35)),
        if (!_locked) ...[
          const SizedBox(height: 10),
          DeadlineBar(
            fraction: (h / 96).clamp(0.0, 1.0),
            color: h < 24 ? const Color(0xFFE6B866) : B.panelAccent,
            track: const Color(0xFF4A3A2C),
          ),
        ],
        if (!mine) ...[
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: _voice, icon: const Icon(Icons.mic, size: 18), label: const Text('Record a voice note')),
        ],
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
              PopupMenuItem(value: 'venue', child: Text('Suggest a place to meet')),
              PopupMenuItem(value: 'not_feeling_it', child: Text('Not feeling it')),
              PopupMenuItem(value: 'report', child: Text('Report')),
              PopupMenuItem(value: 'block', child: Text('Block')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        _voicePanel(),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: Api.messages(_matchId),
            builder: (context, snap) {
              final msgs = snap.data ?? [];
              // their voice note just arrived: refresh the swap panel
              final theirVoice = msgs.any((x) => x['kind'] == 'voice' && x['sender_id'] != Api.me);
              if (theirVoice && _m['voice_theirs'] != true && !_reloading) {
                _reloading = true;
                WidgetsBinding.instance.addPostFrameCallback((_) => _reload().whenComplete(() => _reloading = false));
              }
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
            child: _locked
                ? FilledButton.icon(
                    onPressed: _voice,
                    icon: const Icon(Icons.mic),
                    label: const Text('TEXTING PAUSED · SEND A VOICE NOTE'),
                  )
                : Row(children: [
                    IconButton(tooltip: 'Voice note', onPressed: _voice, icon: Icon(Icons.mic_none, color: B.goldInk)),
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
            topLeft: const Radius.circular(6),
            topRight: const Radius.circular(6),
            bottomLeft: Radius.circular(mine ? 18 : 6),
            bottomRight: Radius.circular(mine ? 6 : 18),
          ),
          border: blocked ? Border.all(color: B.urgent) : null,
          boxShadow: mine || blocked ? null : B.shadow,
        ),
        child: msg['kind'] == 'voice' && msg['audio_path'] != null
            ? VoiceBubble(path: msg['audio_path'] as String, durationMs: (msg['duration_ms'] as num?)?.toInt() ?? 0, mine: mine)
            : Text(
                blocked ? 'Not sent: numbers unlock once you\'ve both sent a voice note.' : msg['body'] as String,
                style: TextStyle(fontSize: 15, height: 1.35, color: blocked ? B.urgent : (mine ? Colors.white : B.ink)),
              ),
      ),
    );
  }
}
