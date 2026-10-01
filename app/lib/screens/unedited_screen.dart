import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// "Unedited": the app picks a question, you get one take of up to 15 seconds. No re-record.
/// Pops `true` when an answer was saved.
class UneditedScreen extends StatefulWidget {
  const UneditedScreen({super.key});
  @override
  State<UneditedScreen> createState() => _UneditedScreenState();
}

enum _Stage { loading, ready, recording, saving, done, error }

class _UneditedScreenState extends State<UneditedScreen> {
  static const _maxMs = 15000;
  final _rec = AudioRecorder();
  _Stage _stage = _Stage.loading;
  String _question = '';
  String _error = '';
  Timer? _tick;
  final _clock = Stopwatch();

  @override
  void initState() {
    super.initState();
    _draw();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _draw() async {
    try {
      final q = await Api.drawVoiceQuestion();
      if (mounted) setState(() {
        _question = q['text'] as String;
        _stage = _Stage.ready;
      });
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    final msg = e.toString().replaceFirst(RegExp(r'^.*?(Exception|Error): '), '');
    if (mounted) setState(() {
      _error = msg.isEmpty ? 'Something went wrong. Try again later.' : msg;
      _stage = _Stage.error;
    });
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) {
        _fail('Microphone access is needed to record your answer.');
        return;
      }
      final path = kIsWeb ? '' : '${(await getTemporaryDirectory()).path}/unedited_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        RecordConfig(encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1),
        path: path,
      );
      _clock
        ..reset()
        ..start();
      setState(() => _stage = _Stage.recording);
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        if (_clock.elapsedMilliseconds >= _maxMs) {
          _stop();
        } else {
          setState(() {});
        }
      });
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _stop() async {
    if (_stage != _Stage.recording) return;
    _tick?.cancel();
    _clock.stop();
    final ms = _clock.elapsedMilliseconds.clamp(0, _maxMs);
    setState(() => _stage = _Stage.saving);
    try {
      final out = await _rec.stop();
      if (out == null) throw 'The recording didn\'t save. Try again later.';
      if (ms < 1000) throw 'That was under a second. Try again in a few minutes.';
      final bytes = await XFile(out).readAsBytes();
      await Api.saveVoiceAnswer(bytes, ms, webm: kIsWeb);
      if (mounted) setState(() => _stage = _Stage.done);
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _clock.elapsedMilliseconds.clamp(0, _maxMs);
    final left = ((_maxMs - elapsed) / 1000).ceil();
    return Scaffold(
      appBar: AppBar(title: Text('Unedited', style: B.heading(22))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionLabel('One take · 15 seconds · no re-recording'),
            const SizedBox(height: 18),
            if (_stage == _Stage.loading) const Expanded(child: Center(child: CircularProgressIndicator())),
            if (_stage == _Stage.error)
              Expanded(
                child: Center(child: Text(_error, textAlign: TextAlign.center, style: TextStyle(color: B.ink2, fontSize: 16, height: 1.4))),
              ),
            if (_stage != _Stage.loading && _stage != _Stage.error) ...[
              Text(_question, style: B.display(32)),
              const SizedBox(height: 14),
              Text(
                _stage == _Stage.ready
                    ? 'Answer the way you\'d say it out loud to a friend. When you tap record, that\'s the take.'
                    : _stage == _Stage.recording
                        ? 'Recording… tap stop when you\'re done.'
                        : _stage == _Stage.saving
                            ? 'Saving…'
                            : 'Saved. It\'s on your profile now. You can answer a new question tomorrow.',
                style: TextStyle(color: B.muted, fontSize: 14, height: 1.45),
              ),
              const Spacer(),
              if (_stage == _Stage.recording) ...[
                Text('0:${left.toString().padLeft(2, '0')}', textAlign: TextAlign.center, style: B.display(48).copyWith(color: B.accent)),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: elapsed / _maxMs, minHeight: 4, color: B.gold, backgroundColor: B.line),
                ),
                const SizedBox(height: 24),
              ],
              if (_stage == _Stage.ready)
                FilledButton.icon(onPressed: _start, icon: const Icon(Icons.mic), label: const Text('RECORD MY ONE TAKE')),
              if (_stage == _Stage.recording)
                FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.stop), label: const Text('STOP')),
              if (_stage == _Stage.saving) const Center(child: CircularProgressIndicator()),
              if (_stage == _Stage.done)
                FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('DONE')),
            ],
          ]),
        ),
      ),
    );
  }
}
