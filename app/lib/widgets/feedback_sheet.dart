import 'package:flutter/material.dart';

import '../services/diagnostics.dart';
import '../theme.dart';
import 'ui.dart';

/// "Report a problem": a bug, something confusing, or an idea. Goes to the admin Activity screen
/// with the screen it came from and the build number attached.
Future<void> showFeedbackSheet(BuildContext context) {
  final where = Diagnostics.screen; // capture before the sheet itself opens
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _FeedbackSheet(screen: where),
  );
}

class _FeedbackSheet extends StatefulWidget {
  const _FeedbackSheet({required this.screen});
  final String screen;
  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  final _body = TextEditingController();
  String _kind = 'bug';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_body.text.trim().isEmpty) {
      setState(() => _error = 'Tell us a little about it.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Diagnostics.sendFeedback(_kind, _body.text.trim(), screen: widget.screen);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thanks. It\'s with us.')));
    } catch (e) {
      final m = RegExp(r'message: ([^,}]+)').firstMatch('$e')?.group(1);
      if (mounted) setState(() {
        _busy = false;
        _error = m ?? 'Couldn\'t send. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Report a problem', style: B.heading(24)),
          const SizedBox(height: 4),
          Text('From: ${widget.screen}', style: TextStyle(color: B.muted, fontSize: 12.5)),
          const SizedBox(height: 12),
          Wrap(spacing: 6, children: [
            PillChip(label: 'Something broke', selected: _kind == 'bug', onTap: () => setState(() => _kind = 'bug')),
            PillChip(label: 'This is confusing', selected: _kind == 'confusing', onTap: () => setState(() => _kind = 'confusing')),
            PillChip(label: 'Idea', selected: _kind == 'idea', onTap: () => setState(() => _kind = 'idea')),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: InputDecoration(
              hintText: switch (_kind) {
                'bug' => 'What happened, and what did you expect?',
                'confusing' => 'What were you trying to do?',
                _ => 'What would make it better?',
              },
            ),
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _busy ? null : _send, child: Text(_busy ? 'Sending…' : 'SEND')),
          ),
        ]),
      );
}
