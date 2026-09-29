import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../theme.dart';

/// Live group or 1:1 chat used by Circles and Market.
/// [names] maps user id -> first name for showing who said what in groups.
class LiveChat extends StatefulWidget {
  const LiveChat({super.key, required this.stream, required this.onSend, this.names = const {}, this.showNames = false, this.hint = 'Message'});
  final Stream<List<Map<String, dynamic>>> stream;
  final Future<void> Function(String body) onSend;
  final Map<String, String> names;
  final bool showNames;
  final String hint;
  @override
  State<LiveChat> createState() => _LiveChatState();
}

class _LiveChatState extends State<LiveChat> {
  final _text = TextEditingController();
  late final Stream<List<Map<String, dynamic>>> _stream = widget.stream;
  bool _sending = false;

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(t);
      _text.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message not sent. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _stream,
          builder: (context, snap) {
            final msgs = (snap.data ?? const []).reversed.toList();
            if (snap.connectionState == ConnectionState.waiting && msgs.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (msgs.isEmpty) {
              return Center(child: Text('No messages yet. Say hi.', style: TextStyle(color: B.muted)));
            }
            return ListView.builder(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              itemCount: msgs.length,
              itemBuilder: (context, i) => _bubble(msgs[i], i + 1 < msgs.length ? msgs[i + 1] : null),
            );
          },
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(hintText: widget.hint),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: B.accent),
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.arrow_upward, color: Colors.white),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _bubble(Map<String, dynamic> m, Map<String, dynamic>? older) {
    final mine = m['sender_id'] == Api.me;
    final sender = m['sender_id'] as String;
    final showName = widget.showNames && !mine && older?['sender_id'] != sender;
    final at = DateTime.parse(m['created_at'] as String).toLocal();
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        if (showName)
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 8, bottom: 2),
            child: Text(widget.names[sender] ?? 'Member',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: B.muted)),
          ),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: const BoxConstraints(maxWidth: 300),
          decoration: BoxDecoration(
            color: mine ? B.panel : B.card,
            borderRadius: BorderRadius.circular(18),
            boxShadow: mine ? null : B.shadow,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m['body'] as String, style: TextStyle(fontSize: 15, height: 1.35, color: mine ? Colors.white : B.ink)),
            const SizedBox(height: 3),
            Text(DateFormat.jm().format(at), style: TextStyle(fontSize: 11, color: mine ? Colors.white60 : B.muted)),
          ]),
        ),
      ]),
    );
  }
}
