import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/pitches_api.dart';
import '../theme.dart';
import '../widgets/live_chat.dart';
import '../widgets/report_sheet.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// Pitches: business ideas and the people who want in.
/// A pitch card is the idea, its stage, the ask and who you are. It goes to members whose
/// "What I'm up for" fits the ask (money to invest, looking for a co-founder, can build apps...).
/// "Let's talk" opens a private chat. No counts anyone can see.
class PitchesScreen extends StatefulWidget {
  const PitchesScreen({super.key});
  @override
  State<PitchesScreen> createState() => _PitchesScreenState();
}

class _PitchesScreenState extends State<PitchesScreen> {
  int _view = 0; // 0 for you, 1 all in your city, 2 mine, 3 chats
  String? _ask; // filter for "All"
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _mine = [];
  List<Map<String, dynamic>> _threads = [];
  Map<String, dynamic>? _options;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _options ??= await PitchesApi.options();
      switch (_view) {
        case 3:
          _threads = await PitchesApi.threads();
        case 2:
          _mine = await PitchesApi.mine();
        case 1:
          _rows = await PitchesApi.pitches(view: 'all', ask: _ask);
        default:
          _rows = await PitchesApi.pitches();
      }
    } catch (e) {
      _toast(PitchesApi.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _openChat(String threadId, String title) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PitchChatScreen(threadId: threadId, title: title)));
    _load();
  }

  Future<void> _talk(Map<String, dynamic> p) async {
    try {
      final existing = p['thread_id'] as String?;
      final thread = existing ?? await PitchesApi.talk(p['pitch_id'] as String);
      if (existing == null) _toast('Chat open with ${p['author_name']}. They\'ll see you reached out.');
      await _openChat(thread, p['author_name'] as String);
    } catch (e) {
      _toast(PitchesApi.errorText(e));
    }
  }

  Future<void> _compose([Map<String, dynamic>? editing]) async {
    final opts = _options;
    if (opts == null) return;
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: B.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _PitchSheet(options: opts, editing: editing),
    );
    if (done == true) {
      _toast(editing == null ? 'Posted. It goes to the people who fit what you\'re asking for.' : 'Saved.');
      if (_view != 2) setState(() => _view = 2);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Row(children: [
            Expanded(child: Text('Pitches', style: B.display(32))),
            FilledButton.icon(onPressed: () => _compose(), icon: const Icon(Icons.add, size: 18), label: const Text('Pitch one')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text('What you\'re building, and who you need to build it. Partners, investors and builders find you here.',
              style: TextStyle(color: B.ink2, fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Segmented(
            options: const ['For you', 'All', 'Mine', 'Chats'],
            index: _view,
            onChanged: (i) {
              setState(() => _view = i);
              _load();
            },
          ),
        ),
        if (_view == 1 && _options != null)
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              children: [
                PillChip(label: 'Anything', selected: _ask == null, onTap: () {
                  setState(() => _ask = null);
                  _load();
                }),
                for (final a in (_options!['asks'] as List).map((e) => Map<String, dynamic>.from(e as Map))) ...[
                  const SizedBox(width: 6),
                  PillChip(label: a['label'] as String, selected: _ask == a['tag'], onTap: () {
                    setState(() => _ask = a['tag'] as String);
                    _load();
                  }),
                ],
              ],
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: switch (_view) { 3 => _chats(), 2 => _mineList(), _ => _list() },
                ),
        ),
      ]),
    );
  }

  Widget _empty(IconData icon, String text) => ListView(children: [
        const SizedBox(height: 90),
        Icon(icon, size: 40, color: B.muted),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: B.ink2, fontWeight: FontWeight.w600, height: 1.4)),
        ),
      ]);

  Widget _list() {
    if (_rows.isEmpty) {
      return _empty(
        Icons.rocket_launch_outlined,
        _view == 0
            ? 'Nothing that fits you yet. Fill in "What I\'m up for" (You → What I\'m up for) so the right pitches find you, or browse All.'
            : 'No pitches here yet. Be the first: what are you building?',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, B.navClearance),
      children: [
        for (final p in _rows) ...[
          _PitchCard(
            pitch: p,
            onTalk: () => _talk(p),
            onHide: () async {
              await PitchesApi.hide(p['pitch_id'] as String).catchError((_) {});
              setState(() => _rows.remove(p));
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _mineList() {
    if (_mine.isEmpty) {
      return _empty(Icons.rocket_launch_outlined,
          'Post a pitch: the idea, where it\'s at, what you need and who you are. It goes to the people who can help.');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, B.navClearance),
      children: [
        for (final p in _mine) ...[
          _MyPitchCard(
            pitch: p,
            onEdit: () => _compose(p),
            onStatus: (s) async {
              try {
                await PitchesApi.setStatus(p['pitch_id'] as String, s);
              } catch (e) {
                _toast(PitchesApi.errorText(e));
              }
              _load();
            },
            onChat: (t, name) => _openChat(t, name),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _chats() {
    if (_threads.isEmpty) return _empty(Icons.forum_outlined, 'No pitch chats yet. Tap "Let\'s talk" on a pitch.');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, B.navClearance),
      children: [
        for (final t in _threads)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            leading: Avatar(path: t['other_photo'] as String?, size: 44),
            title: Text(t['other_name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              '${t['i_am_author'] == true ? 'Your pitch' : 'Their pitch'}: ${t['pitch_idea']}\n${t['last_message'] ?? 'No messages yet'}',
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

List<String> _strings(dynamic v) => v == null ? const [] : List<String>.from((v as List).map((e) => '$e'));

class _StageTag extends StatelessWidget {
  const _StageTag(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(2)),
        child: Text(label.toUpperCase(), style: B.label.copyWith(color: B.gold, fontSize: 9.5)),
      );
}

/// The body every pitch card shares: stage, idea, the ask, who they are.
class _PitchBody extends StatelessWidget {
  const _PitchBody(this.p);
  final Map<String, dynamic> p;
  @override
  Widget build(BuildContext context) {
    final asks = _strings(p['ask_labels']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StageTag(p['stage_label'] as String? ?? ''),
      const SizedBox(height: 8),
      Text(p['idea'] as String, style: const TextStyle(fontSize: 16, height: 1.45, fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Text('LOOKING FOR', style: B.label),
      const SizedBox(height: 4),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final a in asks)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(border: Border.all(color: B.goldInk), borderRadius: BorderRadius.circular(999)),
            child: Text(a, style: TextStyle(color: B.goldInk, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
      ]),
      if (p['ask_note'] != null) ...[
        const SizedBox(height: 6),
        Text(p['ask_note'] as String, style: TextStyle(color: B.ink2, fontSize: 13.5, height: 1.4)),
      ],
      const SizedBox(height: 10),
      Text('WHO\'S PITCHING', style: B.label),
      const SizedBox(height: 4),
      Text(p['about'] as String, style: TextStyle(color: B.ink2, fontSize: 13.5, height: 1.4)),
    ]);
  }
}

class _PitchCard extends StatelessWidget {
  const _PitchCard({required this.pitch, required this.onTalk, required this.onHide});
  final Map<String, dynamic> pitch;
  final VoidCallback onTalk;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final talking = pitch['thread_id'] != null;
    final closed = pitch['status'] == 'closed';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: B.cardBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProfileViewScreen(userId: pitch['author_id'] as String),
              )),
              child: Row(children: [
                Avatar(path: pitch['author_photo'] as String?, size: 34),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(pitch['author_name'] as String,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz, color: B.muted),
            onSelected: (v) {
              if (v == 'hide') onHide();
              if (v == 'report') {
                showReportSheet(context,
                    userId: pitch['author_id'] as String, name: pitch['author_name'] as String, where: 'pitch');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'hide', child: Text('Not for me')),
              PopupMenuItem(value: 'report', child: Text('Report')),
            ],
          ),
        ]),
        Text(closed ? '${pitch['why']} · not taking new conversations' : pitch['why'] as String,
            style: TextStyle(fontSize: 12, color: B.muted)),
        const SizedBox(height: 10),
        _PitchBody(pitch),
        const SizedBox(height: 12),
        if (!closed || talking)
          FilledButton.icon(
            onPressed: onTalk,
            icon: Icon(talking ? Icons.forum_outlined : Icons.handshake_outlined, size: 18),
            label: Text(talking ? 'Open chat' : 'Let\'s talk'),
          ),
      ]),
    );
  }
}

class _MyPitchCard extends StatelessWidget {
  const _MyPitchCard({required this.pitch, required this.onEdit, required this.onStatus, required this.onChat});
  final Map<String, dynamic> pitch;
  final VoidCallback onEdit;
  final void Function(String status) onStatus;
  final void Function(String threadId, String name) onChat;

  @override
  Widget build(BuildContext context) {
    final talkers = List<Map<String, dynamic>>.from(
        (pitch['talkers'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final live = pitch['status'] == 'live';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: B.cardBox(border: live ? null : B.line),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(live ? 'Live' : 'Closed: no new conversations',
                style: TextStyle(fontSize: 12, color: live ? B.ok : B.muted, fontWeight: FontWeight.w700)),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz, color: B.muted),
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'close') onStatus('closed');
              if (v == 'open') onStatus('live');
              if (v == 'remove') onStatus('removed');
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              if (live) const PopupMenuItem(value: 'close', child: Text('Close to new conversations')),
              if (!live) const PopupMenuItem(value: 'open', child: Text('Open it again')),
              const PopupMenuItem(value: 'remove', child: Text('Delete')),
            ],
          ),
        ]),
        _PitchBody(pitch),
        const SizedBox(height: 12),
        Text('REACHED OUT', style: B.label),
        const SizedBox(height: 6),
        if (talkers.isEmpty)
          Text('Nobody yet. It\'s with the people who fit what you asked for.', style: TextStyle(color: B.muted, fontSize: 13))
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in talkers)
              ActionChip(
                avatar: Avatar(path: t['photo'] as String?, size: 22),
                label: Text(t['name'] as String),
                onPressed: () => onChat(t['thread_id'] as String, t['name'] as String),
              ),
          ]),
        const SizedBox(height: 4),
        Text('Only you see who reached out.', style: TextStyle(color: B.muted, fontSize: 11.5)),
      ]),
    );
  }
}

class _PitchSheet extends StatefulWidget {
  const _PitchSheet({required this.options, this.editing});
  final Map<String, dynamic> options;
  final Map<String, dynamic>? editing;
  @override
  State<_PitchSheet> createState() => _PitchSheetState();
}

class _PitchSheetState extends State<_PitchSheet> {
  late final _idea = TextEditingController(text: widget.editing?['idea'] as String? ?? '');
  late final _note = TextEditingController(text: widget.editing?['ask_note'] as String? ?? '');
  late final _about = TextEditingController(text: widget.editing?['about'] as String? ?? '');
  late String? _stage = widget.editing?['stage'] as String?;
  late final Set<String> _asks = {..._strings(widget.editing?['asks'])};
  bool _busy = false;
  String? _error;

  List<Map<String, dynamic>> _opts(String key) =>
      List<Map<String, dynamic>>.from((widget.options[key] as List).map((e) => Map<String, dynamic>.from(e as Map)));

  bool get _ready =>
      _idea.text.trim().length >= 10 && _about.text.trim().length >= 10 && _stage != null && _asks.isNotEmpty;

  @override
  void dispose() {
    _idea.dispose();
    _note.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    try {
      if (widget.editing == null) {
        await PitchesApi.post(idea: _idea.text.trim(), stage: _stage!, asks: _asks.toList(), about: _about.text.trim(), askNote: note);
      } else {
        await PitchesApi.edit(widget.editing!['pitch_id'] as String,
            idea: _idea.text.trim(), stage: _stage!, asks: _asks.toList(), about: _about.text.trim(), askNote: note);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = PitchesApi.errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.editing == null ? 'Pitch an idea' : 'Edit your pitch', style: B.heading(22)),
          const SizedBox(height: 4),
          Text('It goes to members who can answer your ask, not to everyone. Nobody sees a count.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 14),
          Text('THE IDEA', style: B.label),
          TextField(
            controller: _idea,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'e.g. Mobile welding rigs that come to farm sites across southern Alberta'),
          ),
          Text('WHERE IT\'S AT', style: B.label),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in _opts('stages'))
              PillChip(label: s['label'] as String, selected: _stage == s['tag'], onTap: () => setState(() => _stage = s['tag'] as String)),
          ]),
          const SizedBox(height: 14),
          Text('WHAT YOU\'RE LOOKING FOR (UP TO 4)', style: B.label),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in _opts('asks'))
              PillChip(
                label: a['label'] as String,
                selected: _asks.contains(a['tag']),
                onTap: () => setState(() {
                  final t = a['tag'] as String;
                  if (!_asks.remove(t) && _asks.length < 4) _asks.add(t);
                }),
              ),
          ]),
          TextField(
            controller: _note,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'The ask in your words (optional), e.g. 30k to outfit a second truck'),
          ),
          Text('WHO YOU ARE', style: B.label),
          TextField(
            controller: _about,
            maxLength: 300,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'e.g. Red-seal welder, 10 years on rigs, two trucks already',
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
          Text('Contact info, links and handles are blocked. People reach you here.',
              style: TextStyle(fontSize: 12, color: B.muted)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy || !_ready ? null : _save,
            child: Text(_busy ? 'Saving…' : (widget.editing == null ? 'Post pitch' : 'Save')),
          ),
        ]),
      ),
    );
  }
}

/// One private chat about a pitch.
class PitchChatScreen extends StatelessWidget {
  const PitchChatScreen({super.key, required this.threadId, required this.title});
  final String threadId;
  final String title;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: LiveChat(
          stream: PitchesApi.messages(threadId),
          onSend: (b) => PitchesApi.send(threadId, b),
          hint: 'Talk it through, or plan a time to meet',
        ),
      );
}
