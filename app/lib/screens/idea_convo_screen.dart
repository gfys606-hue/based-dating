import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/ideas_api.dart';
import '../theme.dart';
import '../widgets/report_sheet.dart';
import '../widgets/ui.dart';
import 'ideas_screen.dart';
import 'profile_view_screen.dart';

Future<void> openIdeaConvo(BuildContext context, String kind, String id, String title) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => IdeaConvoScreen(kind: kind, id: id, title: title)));

/// The open conversation under an idea or a Based pick.
/// Anyone who can see the idea can read it; you join to write. Members see who else is in. No counts.
class IdeaConvoScreen extends StatefulWidget {
  const IdeaConvoScreen({super.key, required this.kind, required this.id, required this.title});
  final String kind; // 'idea' | 'card'
  final String id;
  final String title;
  @override
  State<IdeaConvoScreen> createState() => _IdeaConvoScreenState();
}

class _IdeaConvoScreenState extends State<IdeaConvoScreen> {
  final _input = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Map<String, dynamic> _data = const {};

  bool get _joined => _data['joined'] == true;
  bool get _isAuthor => _data['is_author'] == true;
  List<Map<String, dynamic>> _list(String k) =>
      List<Map<String, dynamic>>.from(((_data[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _load() async {
    try {
      final d = await IdeasApi.convo(widget.kind, widget.id);
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = IdeasApi.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      await IdeasApi.joinConvo(widget.kind, widget.id);
      await _load();
      _toast('You\'re in. People in the conversation can see you\'re here.');
    } catch (e) {
      _toast(IdeasApi.errorText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _leave() async {
    try {
      await IdeasApi.leaveConvo(widget.kind, widget.id);
      await _load();
      _toast('You left the conversation. You can still read it.');
    } catch (e) {
      _toast(IdeasApi.errorText(e));
    }
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await IdeasApi.comment(widget.kind, widget.id, body);
      _input.clear();
      await _load();
    } catch (e) {
      _toast(IdeasApi.errorText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _postMenu(Map<String, dynamic> p, String action) async {
    try {
      switch (action) {
        case 'remove':
          await IdeasApi.removeComment(p['id'] as String);
          await _load();
        case 'talk':
          final t = p['thread_id'] as String? ?? await IdeasApi.authorTalk(widget.id, p['author_id'] as String);
          if (!mounted) return;
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => IdeaChatScreen(threadId: t, title: p['name'] as String)));
          await _load();
        case 'profile':
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: p['author_id'] as String)));
        case 'report':
          if (!mounted) return;
          await showReportSheet(context, userId: p['author_id'] as String, name: p['name'] as String, where: 'idea conversation');
      }
    } catch (e) {
      _toast(IdeasApi.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final posts = _list('posts');
    final members = _list('members');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversation'),
        actions: [
          if (_joined && !_isAuthor)
            PopupMenuButton<String>(
              onSelected: (_) => _leave(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'leave', child: Text('Leave the conversation'))],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center)))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 16), children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: B.cardBox(border: B.gold),
                          child: Text(widget.title, style: const TextStyle(fontSize: 15.5, height: 1.45, fontWeight: FontWeight.w600)),
                        ),
                        if (_joined && members.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          const SectionLabel('In this conversation'),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 64,
                            child: ListView(scrollDirection: Axis.horizontal, children: [
                              for (final m in members)
                                Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: Column(children: [
                                    Avatar(path: m['photo'] as String?, size: 36),
                                    const SizedBox(height: 4),
                                    Text(m['is_poster'] == true ? '${m['name']} ✦' : m['name'] as String,
                                        style: TextStyle(fontSize: 11.5, color: B.ink2)),
                                  ]),
                                ),
                            ]),
                          ),
                        ],
                        const SizedBox(height: 14),
                        if (posts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 40),
                            child: Text('Nothing here yet. Be the first to say something.',
                                textAlign: TextAlign.center, style: TextStyle(color: B.muted)),
                          ),
                        for (final p in posts) _post(p),
                      ]),
                    ),
                  ),
                  _bottom(),
                ]),
    );
  }

  Widget _post(Map<String, dynamic> p) {
    final push = p['kind'] == 'push';
    final mine = p['mine'] == true;
    final when = DateTime.parse(p['created_at'] as String).toLocal();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Avatar(path: p['photo'] as String?, size: 34),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(
                  mine ? 'You' : p['is_poster'] == true ? '${p['name']} · shared the idea' : p['name'] as String,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 6),
              Text(DateFormat('MMM d, h:mm a').format(when), style: TextStyle(fontSize: 11.5, color: B.muted)),
            ]),
            if (push)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(p['reason'] == null ? '🧊 Pushed back' : '🧊 Pushed back · ${p['reason']}',
                    style: TextStyle(fontSize: 12.5, color: B.goldInk, fontWeight: FontWeight.w700)),
              ),
            if (p['body'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(p['body'] as String, style: const TextStyle(fontSize: 15, height: 1.4)),
              ),
          ]),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: Icon(Icons.more_horiz, color: B.muted, size: 20),
          onSelected: (v) => _postMenu(p, v),
          itemBuilder: (_) => [
            if (_isAuthor && !mine && widget.kind == 'idea')
              const PopupMenuItem(value: 'talk', child: Text('Let\'s talk (private chat)')),
            if (!mine) const PopupMenuItem(value: 'profile', child: Text('See profile')),
            if (mine || _isAuthor) const PopupMenuItem(value: 'remove', child: Text('Remove')),
            if (!mine) const PopupMenuItem(value: 'report', child: Text('Report')),
          ],
        ),
      ]),
    );
  }

  Widget _bottom() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(color: B.card, border: Border(top: BorderSide(color: B.line))),
        child: _joined
            ? Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    maxLength: 500,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Add to the conversation', counterText: ''),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(onPressed: _busy ? null : _send, icon: const Icon(Icons.send)),
              ])
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FilledButton(onPressed: _busy ? null : _join, child: const Text('Join the conversation')),
                const SizedBox(height: 4),
                Text('Anyone who can see this can read it. Join to comment; people in it will see you\'re here.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: B.muted)),
              ]),
      ),
    );
  }
}
