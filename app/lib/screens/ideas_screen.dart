import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/ideas_api.dart';
import '../theme.dart';
import '../widgets/live_chat.dart';
import '../widgets/report_sheet.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// Ideas: short posts whose only job is connecting the right people.
/// Routed to the people an idea fits (not broadcast), "same idea" nudges, I'm in / Let's talk,
/// and turning an idea into a group. No counts anyone else can see.
class IdeasScreen extends StatefulWidget {
  const IdeasScreen({super.key});
  @override
  State<IdeasScreen> createState() => _IdeasScreenState();
}

class _IdeasScreenState extends State<IdeasScreen> {
  int _view = 0; // 0 feed, 1 chats
  bool _loading = true;
  List<Map<String, dynamic>> _ideas = [];
  List<Map<String, dynamic>> _same = [];
  List<Map<String, dynamic>> _threads = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (_view == 1) {
        _threads = await IdeasApi.threads();
      } else {
        final r = await Future.wait([IdeasApi.feed(), IdeasApi.sameIdeas()]);
        _ideas = r[0];
        _same = r[1];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _openChat(String threadId, String title) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => IdeaChatScreen(threadId: threadId, title: title)));
    _load();
  }

  Future<void> _compose() async {
    final posted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: B.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => const _ComposeSheet(),
    );
    if (posted == true) {
      _toast('Posted. It goes to the people it fits.');
      _load();
    }
  }

  Future<void> _respond(Map<String, dynamic> idea, String kind) async {
    try {
      final thread = await IdeasApi.respond(idea['idea_id'] as String, kind);
      if (!mounted) return;
      _toast(kind == 'in' ? 'You\'re in. ${idea['author_name']} will see it.' : 'Chat open with ${idea['author_name']}.');
      await _openChat(thread, idea['author_name'] as String);
    } catch (e) {
      _toast(IdeasApi.errorText(e));
    }
  }

  Future<void> _startGroup(Map<String, dynamic> idea) async {
    final body = idea['body'] as String;
    final name = TextEditingController(text: body.length > 40 ? '' : body);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Start a group'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: name,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Name it, e.g. Mobile welders YYC'),
          ),
          Text('It becomes a Herd. Everyone who said "I\'m in" gets an invite.',
              style: TextStyle(fontSize: 12, color: B.muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('START IT')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await IdeasApi.toGroup(idea['idea_id'] as String, name.text.trim());
      _toast('Group started. Find it in Herd.');
      _load();
    } catch (e) {
      _toast(IdeasApi.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Row(children: [
            Expanded(child: Text('Ideas', style: B.display(32))),
            FilledButton.icon(onPressed: _compose, icon: const Icon(Icons.edit, size: 18), label: const Text('Share one')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text('Don\'t just have an idea, build it. Yours goes to the people it fits, not to everyone.',
              style: TextStyle(color: B.ink2, fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Segmented(
              options: const ['Ideas', 'Chats'],
              index: _view,
              onChanged: (i) {
                setState(() => _view = i);
                _load();
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(onRefresh: _load, child: _view == 1 ? _chats() : _feed()),
        ),
      ]),
    );
  }

  // ---------- feed ----------
  Widget _feed() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, B.navClearance),
      children: [
        if (_same.isNotEmpty) ...[
          const SectionLabel('Thinking alike'),
          const SizedBox(height: 8),
          for (final s in _same) ...[_sameCard(s), const SizedBox(height: 10)],
          const SizedBox(height: 6),
        ],
        if (_ideas.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 80),
            child: Column(children: [
              Icon(Icons.lightbulb_outline, size: 40, color: B.muted),
              const SizedBox(height: 10),
              Text('No ideas here yet. Share what you\'re thinking about building, doing or starting.',
                  textAlign: TextAlign.center, style: TextStyle(color: B.ink2, fontWeight: FontWeight.w600)),
            ]),
          ),
        for (final i in _ideas) ...[
          _IdeaCard(
            idea: i,
            onRespond: (kind) => _respond(i, kind),
            onOpenChat: (thread, title) => _openChat(thread, title),
            onStartGroup: () => _startGroup(i),
            onChanged: _load,
            toast: _toast,
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _sameCard(Map<String, dynamic> s) => Container(
        padding: const EdgeInsets.all(14),
        decoration: B.cardBox(border: B.gold),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Avatar(path: s['author_photo'] as String?, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${s['author_name']} is thinking what you are',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(s['body'] as String, style: const TextStyle(fontSize: 15, height: 1.4)),
          const SizedBox(height: 6),
          Text('You: ${s['my_body']}', maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: B.muted, fontStyle: FontStyle.italic)),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton(
              onPressed: () => _respond({'idea_id': s['idea_id'], 'author_name': s['author_name']}, 'talk'),
              child: const Text('Let\'s talk'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                await IdeasApi.dismiss(s['idea_id'] as String).catchError((_) {});
                setState(() => _same.remove(s));
              },
              child: const Text('Not now'),
            ),
          ]),
        ]),
      );

  // ---------- chats ----------
  Widget _chats() {
    if (_threads.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 120),
        Center(
          child: Text('No idea chats yet. Tap "I\'m in" or "Let\'s talk" on an idea.', style: TextStyle(color: B.muted)),
        ),
      ]);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, B.navClearance),
      children: [
        for (final t in _threads)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            leading: Avatar(path: t['other_photo'] as String?, size: 44),
            title: Text(t['other_name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              '${t['i_am_author'] == true ? 'Your idea' : 'Their idea'}: ${t['idea_body']}\n${t['last_message'] ?? 'No messages yet'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            isThreeLine: true,
            trailing: t['last_message_at'] == null
                ? null
                : Text(DateFormat('MMM d').format(DateTime.parse(t['last_message_at'] as String).toLocal()),
                    style: TextStyle(fontSize: 12, color: B.muted)),
            onTap: () => _openChat(t['thread_id'] as String, t['other_name'] as String),
          ),
      ],
    );
  }
}

class _IdeaCard extends StatelessWidget {
  const _IdeaCard({
    required this.idea,
    required this.onRespond,
    required this.onOpenChat,
    required this.onStartGroup,
    required this.onChanged,
    required this.toast,
  });
  final Map<String, dynamic> idea;
  final void Function(String kind) onRespond;
  final void Function(String threadId, String title) onOpenChat;
  final VoidCallback onStartGroup;
  final VoidCallback onChanged;
  final void Function(String) toast;

  bool get _mine => idea['mine'] == true;

  @override
  Widget build(BuildContext context) {
    final closed = idea['status'] == 'closed';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: B.cardBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: InkWell(
              onTap: _mine
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ProfileViewScreen(userId: idea['author_id'] as String),
                      )),
              child: Row(children: [
                Avatar(path: idea['author_photo'] as String?, size: 34),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(_mine ? 'You' : idea['author_name'] as String,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ),
          Text(_ago(idea['created_at'] as String), style: TextStyle(fontSize: 12, color: B.muted)),
          _menu(context),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(closed ? '${idea['why']} · not taking new people' : idea['why'] as String,
              style: TextStyle(fontSize: 12, color: B.muted)),
        ),
        const SizedBox(height: 8),
        Text(idea['body'] as String, style: const TextStyle(fontSize: 16, height: 1.45)),
        const SizedBox(height: 10),
        if (_mine) _mineActions(context) else _theirActions(closed),
      ]),
    );
  }

  Widget _theirActions(bool closed) {
    final mine = idea['my_response'] as String?;
    final thread = idea['thread_id'] as String?;
    final title = idea['author_name'] as String;
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (!closed || mine != null) ...[
        PillChip(label: mine == 'in' ? 'You\'re in' : 'I\'m in', selected: mine == 'in', onTap: () => onRespond('in')),
        PillChip(label: 'Let\'s talk', selected: mine == 'talk', onTap: () => onRespond('talk')),
      ],
      if (thread != null)
        TextButton.icon(
          onPressed: () => onOpenChat(thread, title),
          icon: const Icon(Icons.chat_bubble_outline, size: 16),
          label: const Text('Open chat'),
        ),
      if (idea['group_name'] != null && mine == 'in')
        Text('Group: ${idea['group_name']} · invite in Herd', style: TextStyle(fontSize: 12, color: B.goldInk)),
    ]);
  }

  Widget _mineActions(BuildContext context) {
    final people = List<Map<String, dynamic>>.from(
        ((idea['responders'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final group = idea['group_name'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (people.isEmpty)
        Text('No one yet. It\'s going to people it fits; only you will see who replies.',
            style: TextStyle(fontSize: 12.5, color: B.muted))
      else ...[
        const SectionLabel('Who\'s replied · only you see this'),
        const SizedBox(height: 6),
        for (final p in people)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Avatar(path: p['photo'] as String?, size: 32),
            title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(p['kind'] == 'in' ? 'I\'m in' : 'Wants to talk'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (group != null && p['kind'] == 'in')
                IconButton(
                  tooltip: 'Invite to the group',
                  icon: const Icon(Icons.group_add_outlined),
                  onPressed: () async {
                    try {
                      await IdeasApi.inviteToGroup(idea['idea_id'] as String, p['user_id'] as String);
                      toast('Invite sent to ${p['name']}.');
                    } catch (e) {
                      toast(IdeasApi.errorText(e));
                    }
                  },
                ),
              if (p['thread_id'] != null)
                IconButton(
                  tooltip: 'Chat',
                  icon: const Icon(Icons.chat_bubble_outline),
                  onPressed: () => onOpenChat(p['thread_id'] as String, p['name'] as String),
                ),
            ]),
          ),
      ],
      const SizedBox(height: 6),
      if (group == null)
        OutlinedButton.icon(
          onPressed: onStartGroup,
          icon: const Icon(Icons.groups_outlined, size: 18),
          label: const Text('Turn it into a group'),
        )
      else
        Row(children: [
          Icon(Icons.groups, size: 18, color: B.goldInk),
          const SizedBox(width: 6),
          Flexible(child: Text('Group: $group · in Herd', style: TextStyle(color: B.goldInk, fontWeight: FontWeight.w600))),
        ]),
    ]);
  }

  Widget _menu(BuildContext context) {
    final id = idea['idea_id'] as String;
    final closed = idea['status'] == 'closed';
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_horiz, color: B.muted),
      onSelected: (v) async {
        try {
          switch (v) {
            case 'close':
              await IdeasApi.setStatus(id, 'closed');
              toast('Closed. People already talking keep their chats.');
            case 'reopen':
              await IdeasApi.setStatus(id, 'live');
              toast('Open again.');
            case 'delete':
              final sure = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text('Delete this idea?'),
                  content: const Text('It disappears for everyone. Chats about it stay.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('DELETE')),
                  ],
                ),
              );
              if (sure != true) return;
              await IdeasApi.setStatus(id, 'removed');
            case 'hide':
              await IdeasApi.dismiss(id);
              toast('Hidden.');
            case 'withdraw':
              await IdeasApi.withdraw(id);
              toast('Taken back.');
            case 'report':
              if (!context.mounted) return;
              await showReportSheet(context, userId: idea['author_id'] as String, name: idea['author_name'] as String, where: 'idea');
              return;
          }
          onChanged();
        } catch (e) {
          toast(IdeasApi.errorText(e));
        }
      },
      itemBuilder: (_) => _mine
          ? [
              closed
                  ? const PopupMenuItem(value: 'reopen', child: Text('Open to new people'))
                  : const PopupMenuItem(value: 'close', child: Text('Stop taking new people')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ]
          : [
              if (idea['my_response'] != null) const PopupMenuItem(value: 'withdraw', child: Text('Take back my reply')),
              const PopupMenuItem(value: 'hide', child: Text('Hide this')),
              const PopupMenuItem(value: 'report', child: Text('Report')),
            ],
    );
  }

  static String _ago(String iso) {
    final d = DateTime.now().difference(DateTime.parse(iso).toLocal());
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return DateFormat('MMM d').format(DateTime.parse(iso).toLocal());
  }
}

class _ComposeSheet extends StatefulWidget {
  const _ComposeSheet();
  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  final _body = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    if (_body.text.trim().length < 3 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await IdeasApi.post(_body.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = IdeasApi.errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Share an idea', style: B.heading(22)),
        const SizedBox(height: 4),
        Text('Something you want to build, start or do. It goes to people whose ideas and interests are close to it.',
            style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
        const SizedBox(height: 12),
        TextField(
          controller: _body,
          autofocus: true,
          maxLength: 280,
          minLines: 3,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'e.g. Want to start a mobile welding business. Have the skills, need a partner with a truck.',
            errorText: _error,
            errorMaxLines: 3,
          ),
        ),
        Text('Contact info, links and handles are blocked. People reach you here.',
            style: TextStyle(fontSize: 12, color: B.muted)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy || _body.text.trim().length < 3 ? null : _post,
          child: Text(_busy ? 'Posting…' : 'Post'),
        ),
      ]),
    );
  }
}

/// One private chat about an idea.
class IdeaChatScreen extends StatelessWidget {
  const IdeaChatScreen({super.key, required this.threadId, required this.title});
  final String threadId;
  final String title;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: LiveChat(
          stream: IdeasApi.messages(threadId),
          onSend: (b) => IdeasApi.send(threadId, b),
          hint: 'Talk it through, or plan a time to meet',
        ),
      );
}

