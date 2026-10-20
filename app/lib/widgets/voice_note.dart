import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/api.dart';
import '../theme.dart';

String _mmss(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Record a voice note for a match and send it. Returns true once sent.
Future<bool> recordVoiceNote(BuildContext context, String matchId) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      builder: (_) => _RecorderSheet(matchId: matchId),
    ) ==
    true;

class _RecorderSheet extends StatefulWidget {
  const _RecorderSheet({required this.matchId});
  final String matchId;
  @override
  State<_RecorderSheet> createState() => _RecorderSheetState();
}

enum _Stage { ready, recording, sending }

class _RecorderSheetState extends State<_RecorderSheet> {
  static const _maxMs = 60000;
  final _rec = AudioRecorder();
  final _clock = Stopwatch();
  Timer? _tick;
  _Stage _stage = _Stage.ready;
  String? _error;

  @override
  void dispose() {
    _tick?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = 'Microphone access is needed to record a voice note.');
        return;
      }
      final path = kIsWeb ? '' : '${(await getTemporaryDirectory()).path}/note_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        RecordConfig(encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1),
        path: path,
      );
      _clock
        ..reset()
        ..start();
      setState(() => _stage = _Stage.recording);
      _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        if (_clock.elapsedMilliseconds >= _maxMs) {
          _send();
        } else {
          setState(() {});
        }
      });
    } catch (e) {
      setState(() => _error = 'Couldn\'t start recording. Try again.');
    }
  }

  Future<void> _cancel() async {
    _tick?.cancel();
    if (_stage == _Stage.recording) {
      try {
        await _rec.cancel();
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context, false);
  }

  Future<void> _send() async {
    if (_stage != _Stage.recording) return;
    _tick?.cancel();
    _clock.stop();
    final ms = _clock.elapsedMilliseconds.clamp(0, _maxMs);
    setState(() => _stage = _Stage.sending);
    try {
      final out = await _rec.stop();
      if (out == null) throw 'The recording didn\'t save. Try again.';
      if (ms < 1500) throw 'Too short. Say a little more.';
      final bytes = await XFile(out).readAsBytes();
      await Api.sendVoice(widget.matchId, bytes, ms, webm: kIsWeb);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.ready;
          _error = e is String ? e : 'Couldn\'t send that. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ms = _clock.elapsedMilliseconds.clamp(0, _maxMs);
    final recording = _stage == _Stage.recording;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Voice note', style: B.heading(24)),
          const SizedBox(height: 4),
          Text(
            recording ? 'Recording… tap send when you\'re done.' : 'Up to a minute. Just talk like you would in person.',
            style: TextStyle(color: B.muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text('${_mmss(ms)} / ${_mmss(_maxMs)}',
                style: B.display(34).copyWith(color: recording ? B.urgent : B.ink)),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: ms / _maxMs, minHeight: 3, color: B.accent, backgroundColor: B.line),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: B.urgent)),
            ),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: OutlinedButton(onPressed: _stage == _Stage.sending ? null : _cancel, child: const Text('CANCEL')),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _stage == _Stage.sending ? null : (recording ? _send : _start),
                icon: Icon(recording ? Icons.send : Icons.mic, size: 18),
                label: Text(_stage == _Stage.sending ? 'SENDING…' : recording ? 'SEND' : 'RECORD'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// A voice note in the chat: play / pause and the length.
class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.path, required this.durationMs, required this.mine});
  final String path;
  final int durationMs;
  final bool mine;
  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _pos;
  StreamSubscription<void>? _done;
  bool _playing = false;
  bool _loading = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _pos = _player.onPositionChanged.listen((p) {
      if (mounted && widget.durationMs > 0) {
        setState(() => _progress = (p.inMilliseconds / widget.durationMs).clamp(0.0, 1.0));
      }
    });
    _done = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _progress = 0;
        });
      }
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
        await _player.play(UrlSource(await Api.voiceNoteUrl(widget.path)));
      }
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn\'t play that. Try again.')));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.mine ? Colors.white : B.ink;
    return SizedBox(
      width: 220,
      child: Row(children: [
        IconButton(
          tooltip: _playing ? 'Pause' : 'Play',
          onPressed: _loading ? null : _toggle,
          icon: _loading
              ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
              : Icon(_playing ? Icons.pause : Icons.play_arrow, color: fg),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 3,
              color: widget.mine ? B.gold : B.accent,
              backgroundColor: widget.mine ? const Color(0x55FFFFFF) : B.line,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(_mmss(widget.durationMs), style: TextStyle(color: fg, fontSize: 12)),
      ]),
    );
  }
}
