import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/signed_photo.dart';
import '../widgets/ui.dart';
import 'circles_screen.dart';
import 'profile_view_screen.dart';

/// Search: one box for everything on Based: people, interests, posts, circles, events, market.
/// If you opt in, what you search helps Based understand what you're really into.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.openModule});
  final void Function(int module) openModule;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  Map<String, dynamic> _r = {};
  bool _loading = false;
  bool _useActivity = false;

  @override
  void initState() {
    super.initState();
    Api.myProfile().then((p) {
      if (mounted) setState(() => _useActivity = p?['use_activity_for_matching'] == true);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _run(v));
  }

  Future<void> _run(String v) async {
    if (v.trim().length < 2) {
      setState(() => _r = {});
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await SocialApi.search(v);
      if (mounted && _q.text == v) setState(() => _r = r);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _list(String k) =>
      ((_r[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  @override
  Widget build(BuildContext context) {
    final empty = _r.isEmpty || ['people', 'topics', 'posts', 'circles', 'events', 'listings'].every((k) => _list(k).isEmpty);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        children: [
          Text('Search', style: B.display(32)),
          const SizedBox(height: 12),
          TextField(
            controller: _q,
            autofocus: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'People, interests, circles, events, stuff for sale…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _loading
                  ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : null,
            ),
            onChanged: _changed,
            onSubmitted: _run,
          ),
          const SizedBox(height: 8),
          _privacyToggle(),
          const SizedBox(height: 8),
          if (_q.text.trim().length >= 2 && !_loading && empty)
            Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Nothing found.', style: TextStyle(color: B.muted)))),
          if (_list('topics').isNotEmpty) ...[
            _label('Interests'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in _list('topics'))
                ActionChip(
                  label: Text(t['name'] as String),
                  onPressed: () {
                    _q.text = t['name'] as String;
                    _run(_q.text);
                  },
                ),
            ]),
          ],
          if (_list('people').isNotEmpty) ...[
            _label('People'),
            for (final p in _list('people'))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Avatar(path: p['photo'] as String?, size: 44),
                title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: p['matched_interests'] == null ? null : Text('Into ${p['matched_interests']}'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: p['id'] as String))),
              ),
          ],
          if (_list('circles').isNotEmpty) ...[
            _label('Circles'),
            for (final c in _list('circles'))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(backgroundColor: B.accentSoft, child: Icon(Icons.bubble_chart, color: B.accent)),
                title: Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${c['members']} members'),
                trailing: c['joined'] == true ? Text('Joined', style: TextStyle(color: B.muted)) : Text('Join', style: TextStyle(color: B.accent, fontWeight: FontWeight.w700)),
                onTap: () => _openCircle(c),
              ),
          ],
          if (_list('events').isNotEmpty) ...[
            _label('Events'),
            for (final e in _list('events'))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.event, color: B.ink2),
                title: Text(e['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text([
                  DateFormat('EEE, MMM d · h:mm a').format(DateTime.parse(e['starts_at'] as String).toLocal()),
                  if (e['place_name'] != null) e['place_name'] as String,
                ].join(' · ')),
                onTap: () => widget.openModule(3),
              ),
          ],
          if (_list('listings').isNotEmpty) ...[
            _label('For sale'),
            for (final l in _list('listings'))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(width: 44, height: 44, child: SignedPhoto(l['photo_path'] as String?, radius: 10)),
                title: Text(l['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                trailing: Text(money(l['price_cents'] as int), style: const TextStyle(fontWeight: FontWeight.w800)),
                onTap: () => widget.openModule(4),
              ),
          ],
          if (_list('posts').isNotEmpty) ...[
            _label('Posts'),
            for (final p in _list('posts'))
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: B.cardBox(),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p['author']} · ${p['topic']}', style: TextStyle(color: B.muted, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(p['body'] as String, maxLines: 4, overflow: TextOverflow.ellipsis),
                ]),
              ),
          ],
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 18, bottom: 6), child: SectionLabel(t));

  Widget _privacyToggle() => Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          Expanded(
            child: Text('Use my searches to improve my matches and circles',
                style: TextStyle(fontSize: 13, color: B.ink2)),
          ),
          Switch(
            value: _useActivity,
            onChanged: (v) async {
              setState(() => _useActivity = v);
              try {
                await SocialApi.setUseActivity(v);
                if (!v) await SocialApi.clearSearchHistory();
              } catch (_) {
                if (mounted) setState(() => _useActivity = !v);
              }
            },
          ),
        ]),
      );

  Future<void> _openCircle(Map<String, dynamic> c) async {
    try {
      if (c['joined'] != true) await SocialApi.joinCircle(c['id'] as String);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CircleScreen(circle: {'circle_id': c['id'], 'name': c['name']}),
      ));
      _run(_q.text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().contains('full') ? 'That circle is full.' : 'Couldn\'t join. Try again.')));
      }
    }
  }
}
