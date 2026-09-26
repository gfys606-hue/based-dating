import 'dart:async';

import 'package:flutter/material.dart';

/// In-app call screen.
///
/// NEXT STEP: plug in a real-time provider (LiveKit recommended — open source, has a Flutter SDK,
/// and sends "room finished" webhooks). The provider's webhook hits supabase/functions/call-webhook,
/// which applies the rules (5-minute minimum, reschedules, video unlock). Nothing is recorded.
///
/// This placeholder shows the UI, the 5-minute progress, and the always-visible report/hang-up controls.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.callId, required this.kind});
  final String callId;
  final String kind;
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _start = DateTime.now();
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(_start);
    final counted = elapsed.inSeconds >= 300;
    final mm = elapsed.inMinutes.toString().padLeft(2, '0');
    final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          const Spacer(),
          Icon(widget.kind == 'video' ? Icons.videocam : Icons.call, color: Colors.white54, size: 96),
          const SizedBox(height: 16),
          Text('$mm:$ss', style: const TextStyle(color: Colors.white, fontSize: 40)),
          const SizedBox(height: 8),
          Text(counted ? 'This call counts ✓' : '${5 - elapsed.inMinutes} min until this call counts',
              style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            TextButton.icon(
              onPressed: () {
                // TODO: report flow → end call with end_reason 'report' (no reschedule used, no penalty)
                Navigator.pop(context);
              },
              icon: const Icon(Icons.flag, color: Colors.white),
              label: const Text('Report', style: TextStyle(color: Colors.white)),
            ),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: Colors.red),
              iconSize: 36,
              onPressed: () async {
                if (!counted) {
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
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.call_end, color: Colors.white),
            ),
          ]),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }
}
