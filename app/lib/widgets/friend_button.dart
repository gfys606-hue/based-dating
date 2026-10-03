import 'package:flutter/material.dart';

import '../services/friends_api.dart';
import '../theme.dart';

/// Add friend / Request sent / Accept / Friends (with inner circle), shown on someone's profile.
/// Hidden when you can't add them (you haven't crossed paths, or it's you).
class FriendButton extends StatefulWidget {
  const FriendButton({super.key, required this.userId, required this.name});
  final String userId;
  final String name;
  @override
  State<FriendButton> createState() => _FriendButtonState();
}

class _FriendButtonState extends State<FriendButton> {
  Map<String, dynamic>? _s;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await FriendsApi.status(widget.userId);
      if (mounted) setState(() => _s = s);
    } catch (_) {}
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst(RegExp(r'^.*?(Exception|Error): ?'), '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg.isEmpty ? 'Try again.' : msg)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _friendMenu() async {
    final inner = _s?['inner'] == true;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(inner ? Icons.star : Icons.star_outline, color: B.gold),
            title: Text(inner ? 'Remove from inner circle' : 'Add to inner circle'),
            subtitle: Text(inner
                ? '${widget.name} will only see what all your friends see.'
                : '${widget.name} will see everything: your plans and your circles.'),
            onTap: () => Navigator.pop(ctx, 'inner'),
          ),
          ListTile(
            leading: Icon(Icons.person_remove_outlined, color: B.muted),
            title: const Text('Remove friend'),
            subtitle: const Text('Your messages with them are deleted. They aren\'t told.'),
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ]),
      ),
    );
    if (v == 'inner') await _run(() => FriendsApi.setInner(widget.userId, !inner));
    if (v == 'remove') await _run(() => FriendsApi.remove(widget.userId));
  }

  @override
  Widget build(BuildContext context) {
    final status = _s?['status'] as String?;
    if (status == null || status == 'self' || status == 'unavailable') return const SizedBox.shrink();

    Widget button;
    switch (status) {
      case 'friends':
        final inner = _s?['inner'] == true;
        button = OutlinedButton.icon(
          onPressed: _busy ? null : _friendMenu,
          icon: Icon(inner ? Icons.star : Icons.check, size: 18, color: inner ? B.gold : B.accentStrong),
          label: Text(inner ? 'INNER CIRCLE' : 'FRIENDS'),
        );
      case 'outgoing':
        button = OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(() => FriendsApi.remove(widget.userId)),
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('REQUEST SENT · TAP TO CANCEL'),
        );
      case 'incoming':
        button = Row(children: [
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : () => _run(() => FriendsApi.respond(widget.userId, true)),
              child: const Text('ACCEPT FRIEND REQUEST'),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _busy ? null : () => _run(() => FriendsApi.respond(widget.userId, false)),
            child: const Text('Not now'),
          ),
        ]);
      default:
        button = FilledButton.icon(
          onPressed: _busy ? null : () => _run(() => FriendsApi.request(widget.userId)),
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: const Text('ADD FRIEND'),
        );
    }

    final met = _s?['met'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      button,
      if (status == 'none' && met != null) ...[
        const SizedBox(height: 6),
        Text(met, style: TextStyle(color: B.muted, fontSize: 12.5)),
      ],
      if (status == 'friends' && _s?['their_inner'] == true) ...[
        const SizedBox(height: 6),
        Text('You\'re in ${widget.name}\'s inner circle.', style: TextStyle(color: B.muted, fontSize: 12.5)),
      ],
    ]);
  }
}
