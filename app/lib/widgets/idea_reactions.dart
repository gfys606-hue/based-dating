import 'package:flutter/material.dart';

import '../screens/idea_convo_screen.dart';
import '../services/friends_api.dart';
import '../services/ideas_api.dart';
import '../theme.dart';
import 'ui.dart';

/// Reactions on ideas and Based picks (supabase/migrations/20261101000052_idea_reactions.sql).
/// Back it / Push back are one tap; reasons and notes are optional. No counts anywhere.

const backReasons = {
  'join': 'I\'d join',
  'know': 'I know someone',
  'done': 'I\'ve done this',
  'pay': 'I\'d pay for it',
};

const pushReasons = {
  'been_done': 'Been done',
  'costly': 'Too costly',
  'timing': 'Bad timing',
  'twist': 'Needs a twist',
  'unrealistic': 'Not realistic',
};

const temperatureLabels = {
  'cold': '🧊 Cold',
  'warming': '🌤 Warming up',
  'warm': '🔥 Warm',
  'hot': '🔥🔥 Hot',
};

/// The Back it / Push back / Conversation row under someone else's idea or a Based pick.
/// [state] is this item's row from IdeasApi.reactions (it's updated in place).
class ReactBar extends StatefulWidget {
  const ReactBar({
    super.key,
    required this.kind,
    required this.id,
    required this.title,
    required this.state,
    required this.toast,
    this.onChat,
    this.onConvoClosed,
  });
  final String kind; // 'idea' | 'card'
  final String id;
  final String title;
  final Map<String, dynamic> state;
  final void Function(String) toast;
  final void Function(String threadId)? onChat; // "I'd join" opened a chat with the author
  final VoidCallback? onConvoClosed;

  @override
  State<ReactBar> createState() => _ReactBarState();
}

class _ReactBarState extends State<ReactBar> {
  bool _busy = false;

  String? get _mine => widget.state['my_reaction'] as String?;
  String? get _reason => widget.state['my_reason'] as String?;

  Future<Map<String, dynamic>?> _send(String? reaction, {String? reason, String? note, String? tag}) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final res = await IdeasApi.react(widget.kind, widget.id, reaction, reason: reason, note: note, tag: tag);
      widget.state
        ..['my_reaction'] = reaction
        ..['my_reason'] = reason
        ..['my_note'] = note;
      if (reaction == 'push' && (reason != null || note != null)) {
        widget.state['joined'] = true;
        widget.state['has_convo'] = true;
      }
      if (reaction == 'back' && reason == 'join' && widget.kind == 'card') widget.state['joined'] = true;
      return res;
    } catch (e) {
      widget.toast(IdeasApi.errorText(e));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _back() async {
    if (_mine == 'back') {
      await _send(null);
      return;
    }
    final res = await _send('back');
    if (res == null) return;
    final left = (res['backs_left'] as num?)?.toInt();
    widget.toast(left == null ? 'Backed.' : 'Backed. $left ${left == 1 ? 'back' : 'backs'} left today.');
  }

  Future<void> _pickReason(String r) async {
    if (_reason == r) {
      await _send('back'); // tap the selected reason again to clear it
      return;
    }
    String? tag;
    if (r == 'know') {
      tag = await _pickFriend();
      if (tag == null) return;
    }
    final res = await _send('back', reason: r, tag: tag);
    if (res == null) return;
    final thread = res['thread_id'] as String?;
    if (r == 'know') widget.toast('Sent their way.');
    if (r == 'join' && widget.kind == 'card') widget.toast('You\'re in the conversation.');
    if (thread != null) widget.onChat?.call(thread);
  }

  Future<String?> _pickFriend() async {
    List<Map<String, dynamic>> friends;
    try {
      friends = await FriendsApi.friends();
    } catch (e) {
      widget.toast(IdeasApi.errorText(e));
      return null;
    }
    if (!mounted) return null;
    if (friends.isEmpty) {
      widget.toast('Add some friends first. You can only send ideas to friends.');
      return null;
    }
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: B.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 20, 16, 16), children: [
          Text('Who should see this?', style: B.heading(20)),
          const SizedBox(height: 4),
          Text('It goes to them in Ideas, with a note that you thought of them.',
              style: TextStyle(color: B.muted, fontSize: 13)),
          const SizedBox(height: 8),
          for (final f in friends)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Avatar(path: f['photo'] as String?, size: 38),
              title: Text(f['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(ctx, f['user_id'] as String),
            ),
        ]),
      ),
    );
  }

  Future<void> _push() async {
    if (_mine == 'push') {
      await _send(null);
      return;
    }
    if (await _send('push') == null) return;
    await _editPush(fresh: true);
  }

  Future<void> _editPush({bool fresh = false}) async {
    final out = await showModalBottomSheet<(String?, String?)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: B.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _PushSheet(reason: fresh ? null : _reason, note: fresh ? null : widget.state['my_note'] as String?),
    );
    if (out == null) {
      if (fresh) widget.toast('Pushed back.');
      return;
    }
    final (reason, note) = out;
    if (reason == null && note == null) return;
    if (await _send('push', reason: reason, note: note) != null) {
      widget.toast('Pushed back. It\'s in the conversation.');
    }
  }

  Future<void> _openConvo() async {
    await openIdeaConvo(context, widget.kind, widget.id, widget.title);
    widget.onConvoClosed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final mine = _mine;
    final hasConvo = widget.state['has_convo'] == true;
    final joined = widget.state['joined'] == true;
    final note = widget.state['my_note'] as String?;
    final pushParts = [
      if (_reason != null && pushReasons[_reason] != null) pushReasons[_reason]!,
      if (note != null) '"$note"',
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        PillChip(label: mine == 'back' ? '🔥 Backed' : '🔥 Back it', selected: mine == 'back', onTap: _back),
        PillChip(label: mine == 'push' ? '🧊 Pushed back' : '🧊 Push back', selected: mine == 'push', onTap: _push),
        TextButton.icon(
          onPressed: _openConvo,
          icon: const Icon(Icons.forum_outlined, size: 16),
          label: Text(joined ? 'Conversation · you\'re in' : hasConvo ? 'Conversation' : 'Start the conversation'),
        ),
      ]),
      if (mine == 'back') ...[
        const SizedBox(height: 8),
        Text('Why? Optional, but it helps it reach the right people.', style: TextStyle(fontSize: 12, color: B.muted)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in backReasons.entries)
            PillChip(label: e.value, selected: _reason == e.key, onTap: () => _pickReason(e.key)),
        ]),
      ],
      if (mine == 'push') ...[
        const SizedBox(height: 6),
        InkWell(
          onTap: _editPush,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              pushParts.isEmpty ? 'Add a reason or a note (optional)' : '${pushParts.join(' · ')}  ·  edit',
              style: TextStyle(fontSize: 12.5, color: B.goldInk, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    ]);
  }
}

/// Optional reason + optional one-line note for a push back.
class _PushSheet extends StatefulWidget {
  const _PushSheet({this.reason, this.note});
  final String? reason;
  final String? note;
  @override
  State<_PushSheet> createState() => _PushSheetState();
}

class _PushSheetState extends State<_PushSheet> {
  late String? _reason = widget.reason;
  late final _note = TextEditingController(text: widget.note ?? '');

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = _note.text.trim();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Pushed back', style: B.heading(22)),
        const SizedBox(height: 4),
        Text('Want to say why? Both are optional. A reason or note goes into the idea\'s conversation, '
            'where anyone who can see the idea can read it.',
            style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in pushReasons.entries)
            PillChip(
              label: e.value,
              selected: _reason == e.key,
              onTap: () => setState(() => _reason = _reason == e.key ? null : e.key),
            ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          maxLength: 200,
          maxLines: 2,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: 'One line, e.g. Permits will kill this (optional)'),
        ),
        const SizedBox(height: 8),
        Row(children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
          const Spacer(),
          FilledButton(
            onPressed: _reason == null && note.isEmpty
                ? null
                : () => Navigator.pop(context, (_reason, note.isEmpty ? null : note)),
            child: const Text('Add it'),
          ),
        ]),
      ]),
    );
  }
}

/// On your own idea: the private temperature and who backed or pushed back, and why.
class OwnIdeaReactions extends StatelessWidget {
  const OwnIdeaReactions({
    super.key,
    required this.ideaId,
    required this.title,
    required this.state,
    required this.onChat,
    required this.toast,
    this.onConvoClosed,
  });
  final String ideaId;
  final String title;
  final Map<String, dynamic> state;
  final void Function(String threadId, String name) onChat;
  final void Function(String) toast;
  final VoidCallback? onConvoClosed;

  @override
  Widget build(BuildContext context) {
    final temp = state['temperature'] as String? ?? 'cold';
    final people = List<Map<String, dynamic>>.from(
        ((state['reactors'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(20)),
          child: Text(temperatureLabels[temp] ?? temp, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        const SizedBox(width: 8),
        Flexible(child: Text('Temperature · only you see this', style: TextStyle(fontSize: 12, color: B.muted))),
        const Spacer(),
        TextButton.icon(
          onPressed: () async {
            await openIdeaConvo(context, 'idea', ideaId, title);
            onConvoClosed?.call();
          },
          icon: const Icon(Icons.forum_outlined, size: 16),
          label: Text(state['has_convo'] == true ? 'Conversation' : 'Open conversation'),
        ),
      ]),
      if (people.isNotEmpty) ...[
        const SizedBox(height: 6),
        const SectionLabel('Who reacted · only you see this'),
        const SizedBox(height: 4),
        for (final p in people)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Avatar(path: p['photo'] as String?, size: 32),
            title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              p['reaction'] == 'back' ? '🔥 Backed it' : '🧊 Pushed back',
              if (p['reason'] != null) p['reason'] as String,
              if (p['note'] != null) '"${p['note']}"',
            ].join(' · ')),
            trailing: IconButton(
              tooltip: 'Let\'s talk',
              icon: const Icon(Icons.chat_bubble_outline),
              onPressed: () async {
                try {
                  final t = p['thread_id'] as String? ?? await IdeasApi.authorTalk(ideaId, p['user_id'] as String);
                  onChat(t, p['name'] as String);
                } catch (e) {
                  toast(IdeasApi.errorText(e));
                }
              },
            ),
          ),
      ],
    ]);
  }
}
