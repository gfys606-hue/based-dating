import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import '../services/api.dart';

/// In-app voice / video call (LiveKit). Nothing is recorded.
///
/// The server (livekit-webhook) is the source of truth for the 5-minute rule:
/// the clock starts when both people are in the call and stops when the first one leaves.
/// The timer here mirrors that so people can see when the call "counts".
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.callId,
    required this.kind,
    required this.matchId,
    required this.otherId,
  });
  final String callId;
  final String kind;
  final String matchId;
  final String otherId;
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _room = Room(roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true));
  EventsListener<RoomEvent>? _listener;
  Timer? _tick;

  bool _connecting = true;
  String? _error;
  DateTime? _bothInSince; // when the other person was first here with us
  bool _otherLeft = false;
  bool _micOn = true;
  bool _camOn = false;
  bool _leaving = false;

  bool get _video => widget.kind == 'video';

  @override
  void initState() {
    super.initState();
    _camOn = _video;
    _connect();
  }

  Future<void> _connect() async {
    try {
      final res = await Api.db.functions.invoke('call-token', body: {'call_id': widget.callId});
      final data = Map<String, dynamic>.from(res.data as Map);
      if (data['error'] != null) throw data['error'] as String;

      _listener = _room.createListener()
        ..on<ParticipantConnectedEvent>((_) => _otherArrived())
        ..on<TrackSubscribedEvent>((_) => setState(() {}))
        ..on<TrackUnsubscribedEvent>((_) => setState(() {}))
        ..on<ParticipantDisconnectedEvent>((_) => setState(() => _otherLeft = true))
        ..on<RoomDisconnectedEvent>((_) {
          if (mounted && !_leaving) Navigator.of(context).pop();
        });

      await _room.connect(data['url'] as String, data['token'] as String);
      await _room.localParticipant?.setMicrophoneEnabled(true);
      if (_video) await _room.localParticipant?.setCameraEnabled(true);

      if (_room.remoteParticipants.isNotEmpty) _otherArrived();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      if (mounted) setState(() => _connecting = false);
    } on FunctionException catch (e) {
      final details = e.details;
      final msg = details is Map && details['error'] != null ? details['error'].toString() : 'Could not start the call.';
      if (mounted) setState(() { _connecting = false; _error = msg; });
    } catch (e) {
      if (mounted) setState(() { _connecting = false; _error = e is String ? e : 'Could not start the call. Check your connection and try again.'; });
    }
  }

  void _otherArrived() {
    if (!mounted) return;
    setState(() {
      _bothInSince ??= DateTime.now();
      _otherLeft = false;
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _listener?.dispose();
    _room.disconnect();
    _room.dispose();
    super.dispose();
  }

  Duration get _elapsed => _bothInSince == null ? Duration.zero : DateTime.now().difference(_bothInSince!);
  bool get _counted => _elapsed.inSeconds >= 300;

  Future<void> _leave() async {
    _leaving = true;
    await _room.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _hangUp() async {
    if (_bothInSince != null && !_counted && !_otherLeft) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('End before 5 minutes?'),
          content: const Text('Calls under 5 minutes use one of this match\'s 2 reschedules.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End call')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _leave();
  }

  Future<void> _report() async {
    final cat = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Report and leave the call. This won\'t use a reschedule.', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          for (final c in const {
            'harassment': 'Harassment',
            'explicit': 'Explicit content',
            'threats': 'Threats or violence',
            'fake_profile': 'Not the person in the photos',
            'scam': 'Scam or asking for money',
            'underage': 'May be under 18',
          }.entries)
            ListTile(title: Text(c.value), onTap: () => Navigator.pop(ctx, c.key)),
        ]),
      ),
    );
    if (cat == null) return;
    try {
      await Api.report(widget.otherId, cat, matchId: widget.matchId);
    } catch (_) {}
    await _leave();
  }

  VideoTrack? _remoteVideo() {
    for (final p in _room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (pub.subscribed && pub.track != null && !pub.muted) return pub.track as VideoTrack;
      }
    }
    return null;
  }

  VideoTrack? _localVideo() {
    final pubs = _room.localParticipant?.videoTrackPublications ?? const [];
    for (final pub in pubs) {
      if (pub.track != null && !pub.muted) return pub.track as VideoTrack;
    }
    return null;
  }

  String get _status {
    if (_connecting) return 'Connecting…';
    if (_bothInSince == null) return 'Waiting for your match to join…';
    if (_otherLeft) return 'Your match left the call';
    if (_counted) return 'This call counts ✓';
    return '${5 - _elapsed.inMinutes} min until this call counts';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.call_end, color: Colors.white54, size: 64),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17)),
                const SizedBox(height: 24),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
              ]),
            ),
          ),
        ),
      );
    }

    final e = _elapsed;
    final mm = e.inMinutes.toString().padLeft(2, '0');
    final ss = (e.inSeconds % 60).toString().padLeft(2, '0');
    final remote = _video ? _remoteVideo() : null;
    final local = _video ? _localVideo() : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        if (remote != null)
          Positioned.fill(child: VideoTrackRenderer(remote, fit: VideoViewFit.cover))
        else
          const Center(child: Icon(Icons.person, color: Colors.white24, size: 120)),
        if (local != null)
          Positioned(
            right: 16,
            top: MediaQuery.of(context).padding.top + 16,
            width: 110,
            height: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: VideoTrackRenderer(local, fit: VideoViewFit.cover),
            ),
          ),
        SafeArea(
          child: Column(children: [
            const SizedBox(height: 24),
            Text('$mm:$ss', style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(_status, style: const TextStyle(color: Colors.white70)),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              TextButton.icon(
                onPressed: _connecting ? null : _report,
                icon: const Icon(Icons.flag, color: Colors.white),
                label: const Text('Report', style: TextStyle(color: Colors.white)),
              ),
              IconButton(
                iconSize: 30,
                color: Colors.white,
                onPressed: _connecting
                    ? null
                    : () async {
                        _micOn = !_micOn;
                        await _room.localParticipant?.setMicrophoneEnabled(_micOn);
                        setState(() {});
                      },
                icon: Icon(_micOn ? Icons.mic : Icons.mic_off),
              ),
              if (_video)
                IconButton(
                  iconSize: 30,
                  color: Colors.white,
                  onPressed: _connecting
                      ? null
                      : () async {
                          _camOn = !_camOn;
                          await _room.localParticipant?.setCameraEnabled(_camOn);
                          setState(() {});
                        },
                  icon: Icon(_camOn ? Icons.videocam : Icons.videocam_off),
                ),
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: const Color(0xFF4169E1)),
                iconSize: 36,
                onPressed: _hangUp,
                icon: const Icon(Icons.call_end, color: Colors.white),
              ),
            ]),
            const SizedBox(height: 32),
          ]),
        ),
      ]),
    );
  }
}
