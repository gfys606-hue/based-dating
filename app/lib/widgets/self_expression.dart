import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import 'ui.dart';

/// "Unedited": the question and a play button for someone's one-take voice answer.
class VoiceNoteCard extends StatefulWidget {
  const VoiceNoteCard({super.key, required this.voice, this.trailing});
  final Map<String, dynamic> voice; // {question, path, duration_ms}
  final Widget? trailing;
  @override
  State<VoiceNoteCard> createState() => _VoiceNoteCardState();
}

class _VoiceNoteCardState extends State<VoiceNoteCard> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _pos;
  StreamSubscription<void>? _done;
  bool _playing = false;
  bool _loading = false;
  double _progress = 0;

  int get _ms => (widget.voice['duration_ms'] as num?)?.toInt() ?? 15000;

  @override
  void initState() {
    super.initState();
    _pos = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _progress = (p.inMilliseconds / _ms).clamp(0.0, 1.0));
    });
    _done = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() {
        _playing = false;
        _progress = 0;
      });
    });
  }

  @override
  void dispose() {
    _pos?.cancel();
    _done?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    setState(() => _loading = true);
    try {
      if (_progress > 0) {
        await _player.resume();
      } else {
        final url = await Api.voiceUrl(widget.voice['path'] as String);
        await _player.play(UrlSource(url));
      }
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn\'t play that. Try again.')));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final secs = (_ms / 1000).round();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: B.cardBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: SectionLabel('Unedited · one take', color: B.accentStrong)),
          if (widget.trailing != null) widget.trailing!,
        ]),
        const SizedBox(height: 8),
        Text(widget.voice['question'] as String? ?? '', style: B.heading(19)),
        const SizedBox(height: 12),
        Row(children: [
          IconButton.filled(
            tooltip: _playing ? 'Pause' : 'Play',
            style: IconButton.styleFrom(backgroundColor: B.gold, foregroundColor: B.onGold, minimumSize: const Size(46, 46)),
            onPressed: _loading ? null : _toggle,
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: B.onGold))
                : Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: _progress, minHeight: 3, color: B.accent, backgroundColor: B.line),
            ),
          ),
          const SizedBox(width: 12),
          Text('0:${secs.toString().padLeft(2, '0')}', style: TextStyle(color: B.muted, fontSize: 12)),
        ]),
      ]),
    );
  }
}

/// "Respectfully agree or disagree": the statement, plus (for others) two buttons; (for you) the totals.
class StanceCard extends StatefulWidget {
  const StanceCard({super.key, required this.userId, required this.stance, required this.isMe, this.trailing});
  final String userId;
  final Map<String, dynamic> stance; // {statement, my_verdict, agree?, disagree?}
  final bool isMe;
  final Widget? trailing;
  @override
  State<StanceCard> createState() => _StanceCardState();
}

class _StanceCardState extends State<StanceCard> {
  late String? _verdict = widget.stance['my_verdict'] as String?;
  bool _busy = false;

  Future<void> _pick(String v) async {
    final next = _verdict == v ? '' : v;
    final before = _verdict;
    setState(() {
      _verdict = next.isEmpty ? null : next;
      _busy = true;
    });
    try {
      await Api.reactStance(widget.userId, next);
    } catch (_) {
      if (mounted) setState(() => _verdict = before);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final agree = widget.stance['agree'];
    final disagree = widget.stance['disagree'];
    Widget choice(String v, String label) {
      final on = _verdict == v;
      return Expanded(
        child: OutlinedButton(
          onPressed: _busy ? null : () => _pick(v),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: on ? B.accent : null,
            foregroundColor: on ? Colors.white : B.ink,
            side: BorderSide(color: on ? B.accent : B.line),
            textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.0),
          ),
          child: Text(label),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: B.cardBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: SectionLabel('Respectfully agree or disagree', color: B.accentStrong)),
          if (widget.trailing != null) widget.trailing!,
        ]),
        const SizedBox(height: 8),
        Text('“${widget.stance['statement']}”', style: B.heading(21).copyWith(fontStyle: FontStyle.italic)),
        const SizedBox(height: 14),
        if (widget.isMe)
          Text('${agree ?? 0} agree · ${disagree ?? 0} respectfully disagree · only you see this',
              style: TextStyle(color: B.muted, fontSize: 12.5))
        else
          Row(children: [
            choice('agree', 'AGREE'),
            const SizedBox(width: 8),
            choice('disagree', 'RESPECTFULLY DISAGREE'),
          ]),
      ]),
    );
  }
}

/// "Lately": filled in from real activity on Based. Nobody writes it.
class LatelyStrip extends StatelessWidget {
  const LatelyStrip({super.key, required this.items, this.emptyText});
  final List<Map<String, dynamic>> items;
  final String? emptyText;

  static IconData _icon(String kind) => switch (kind) {
        'topic' => Icons.local_fire_department_outlined,
        'event' => Icons.event_outlined,
        'posts' => Icons.edit_note,
        'circles' => Icons.bubble_chart_outlined,
        _ => Icons.auto_awesome_outlined,
      };

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && emptyText == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel('Lately', color: B.accentStrong),
      const SizedBox(height: 8),
      if (items.isEmpty)
        Text(emptyText!, style: TextStyle(color: B.muted, fontSize: 13, height: 1.4))
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final it in items)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: B.accentSoft,
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: B.line, width: 0.8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_icon(it['kind'] as String? ?? ''), size: 15, color: B.accentStrong),
                const SizedBox(width: 6),
                Text(it['label'] as String? ?? '', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: B.ink)),
              ]),
            ),
        ]),
    ]);
  }
}
