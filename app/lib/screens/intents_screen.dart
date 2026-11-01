import 'package:flutter/material.dart';

import '../services/intents_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// What I'm up for: Looking for (right now), I'm available for, I can, I need — and the people
/// nearby whose picks fit yours, each with the plain-English reason.
class IntentsScreen extends StatefulWidget {
  const IntentsScreen({super.key, this.startOnMatches = false});
  final bool startOnMatches;
  @override
  State<IntentsScreen> createState() => _IntentsScreenState();
}

class _IntentsScreenState extends State<IntentsScreen> {
  late int _view = widget.startOnMatches ? 1 : 0; // 0 mine, 1 matches
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  Map<String, List<Map<String, dynamic>>> _options = {};
  List<Map<String, dynamic>> _matches = [];

  // kind -> selected tags (in pick order); notes for I can / I need; when each looking-for runs out
  final Map<String, List<String>> _picked = {'looking': [], 'available': [], 'can': [], 'need': []};
  final Map<String, TextEditingController> _notes = {};
  final Map<String, DateTime> _expires = {};

  static const _maxPerList = 6;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _noteKey(String kind, String tag) => '$kind:$tag';

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (_view == 1) {
        _matches = await IntentsApi.matches();
      } else {
        final r = await Future.wait([IntentsApi.options(), IntentsApi.mine()]);
        _options = r[0] as Map<String, List<Map<String, dynamic>>>;
        for (final l in _picked.values) {
          l.clear();
        }
        _expires.clear();
        for (final i in r[1] as List<Map<String, dynamic>>) {
          final kind = i['kind'] as String;
          final tag = i['tag'] as String;
          _picked[kind]?.add(tag);
          if (i['note'] != null) {
            _notes.putIfAbsent(_noteKey(kind, tag), () => TextEditingController()).text = i['note'] as String;
          }
          if (i['expires_at'] != null) _expires[tag] = DateTime.parse(i['expires_at'] as String).toLocal();
        }
        _dirty = false;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _toggle(String kind, String tag) {
    final list = _picked[kind]!;
    setState(() {
      if (list.contains(tag)) {
        list.remove(tag);
      } else if (list.length >= _maxPerList) {
        _toast('Pick up to $_maxPerList here.');
        return;
      } else {
        list.add(tag);
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final items = <Map<String, dynamic>>[];
    for (final e in _picked.entries) {
      for (final tag in e.value) {
        final note = _notes[_noteKey(e.key, tag)]?.text.trim();
        items.add({
          'kind': e.key,
          'tag': tag,
          if ((e.key == 'can' || e.key == 'need') && note != null && note.isNotEmpty) 'note': note,
        });
      }
    }
    try {
      await IntentsApi.save(items);
      _toast('Saved. People nearby who fit will show up under Matches.');
      await _load();
    } catch (e) {
      _toast(IntentsApi.errorText(e));
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _renew(String tag) async {
    try {
      await IntentsApi.renew(tag);
      _toast('Good for another 2 weeks.');
      _load();
    } catch (e) {
      _toast(IntentsApi.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('What I\'m up for')),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Segmented(
              options: const ['Mine', 'Matches'],
              index: _view,
              onChanged: (i) async {
                if (_dirty && i == 1) await _save();
                setState(() => _view = i);
                _load();
              },
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(onRefresh: _load, child: _view == 1 ? _matchesList() : _mine()),
        ),
        if (_view == 0 && !_loading)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: FilledButton(
                onPressed: _saving || !_dirty ? null : _save,
                child: Text(_saving ? 'Saving…' : (_dirty ? 'Save' : 'Saved')),
              ),
            ),
          ),
      ]),
    );
  }

  // ---------- mine ----------
  Widget _mine() {
    final skills = _options['skills'] ?? const [];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Text('Don\'t just follow people, meet them. Pick what you\'re up for and Based finds the people nearby who fit.',
            style: TextStyle(color: B.ink2, fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _section('looking', 'Looking for right now', 'Each one lasts 2 weeks, so it stays current. Renew it if you\'re still looking.',
            _options['looking'] ?? const []),
        _section('available', 'I\'m available for', 'What people can ask you to join.', _options['available'] ?? const []),
        _section('can', 'I can', 'Skills, money, gear or time you can bring. Add a short note if it helps.', skills),
        _section('need', 'I need', 'What would move your idea or project forward.', skills),
        Text('Dating is shown on your profile only; matching for dates stays in Ouch.',
            style: TextStyle(fontSize: 12, color: B.muted)),
      ],
    );
  }

  Widget _section(String kind, String title, String hint, List<Map<String, dynamic>> options) {
    final picked = _picked[kind]!;
    final labels = {for (final o in options) o['tag'] as String: o['label'] as String};
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionLabel(title),
        const SizedBox(height: 4),
        Text(hint, style: TextStyle(fontSize: 12.5, color: B.muted, height: 1.35)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final o in options)
            PillChip(
              label: o['label'] as String,
              selected: picked.contains(o['tag']),
              onTap: () => _toggle(kind, o['tag'] as String),
            ),
        ]),
        if (kind == 'looking')
          for (final tag in picked)
            if (_expires[tag] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Expanded(
                    child: Text('${labels[tag]} · ${_daysLeft(_expires[tag]!)}',
                        style: TextStyle(fontSize: 12.5, color: B.ink2)),
                  ),
                  TextButton(onPressed: () => _renew(tag), child: const Text('Keep looking')),
                ]),
              ),
        if (kind == 'can' || kind == 'need')
          for (final tag in picked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _notes.putIfAbsent(_noteKey(kind, tag), () => TextEditingController()),
                maxLength: 120,
                onChanged: (_) => setState(() => _dirty = true),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: '${labels[tag]} · note (optional)',
                  hintText: kind == 'need' ? 'e.g. for a mobile welding booking app' : 'e.g. 10 years doing this',
                ),
              ),
            ),
      ]),
    );
  }

  static String _daysLeft(DateTime t) {
    final d = t.difference(DateTime.now());
    if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} left';
    if (d.inHours >= 1) return '${d.inHours} hours left';
    return 'ends soon';
  }

  // ---------- matches ----------
  Widget _matchesList() {
    if (_matches.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 100),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'No matches yet. Add a few things under Mine; when someone nearby fits, they show up here and you get a heads-up.',
            textAlign: TextAlign.center,
            style: TextStyle(color: B.muted, height: 1.4),
          ),
        ),
      ]);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        for (final m in _matches) ...[
          InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: m['user_id'] as String)),
            ),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: B.cardBox(),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Avatar(path: m['photo'] as String?, size: 46),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      '${m['name']}${m['age'] == null ? '' : ', ${m['age']}'}${m['is_friend'] == true ? ' · friend' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5),
                    ),
                    const SizedBox(height: 6),
                    for (final r in List<String>.from(m['reasons'] as List? ?? const []))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(Icons.check, size: 15, color: B.goldInk),
                          const SizedBox(width: 6),
                          Expanded(child: Text(r, style: TextStyle(fontSize: 13.5, color: B.ink2))),
                        ]),
                      ),
                  ]),
                ),
                Icon(Icons.chevron_right, color: B.muted),
              ]),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// Someone's "up for" picks on their profile; the ones that fit yours are highlighted.
class ProfileIntents extends StatelessWidget {
  const ProfileIntents({super.key, required this.userId});
  final String userId;

  static const _titles = {
    'looking': 'Looking for right now',
    'available': 'Available for',
    'can': 'Can',
    'need': 'Needs',
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: IntentsApi.ofUser(userId).catchError((_) => <Map<String, dynamic>>[]),
      builder: (context, snap) {
        final items = snap.data ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final kind in _titles.keys)
              if (items.any((i) => i['kind'] == kind)) ...[
                SectionLabel(_titles[kind]!),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final i in items.where((i) => i['kind'] == kind))
                    Tooltip(
                      message: (i['note'] as String?) ?? '',
                      child: Chip(
                        label: Text(i['note'] == null ? i['label'] as String : '${i['label']}: ${i['note']}'),
                        avatar: i['fits'] == true ? Icon(Icons.check, size: 16, color: B.goldInk) : null,
                        side: i['fits'] == true ? BorderSide(color: B.gold) : null,
                      ),
                    ),
                ]),
                const SizedBox(height: 10),
              ],
          ]),
        );
      },
    );
  }
}
