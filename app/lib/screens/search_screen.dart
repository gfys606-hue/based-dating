import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../services/places_api.dart';
import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// Search, kept inside Based: find people you know and places to go.
/// Empty box: people you may know, places your friends go, and your friends' plans.
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
  bool _loading = true;
  int _filter = 0; // 0 everything, 1 people, 2 places
  final _saved = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(v));
  }

  Future<void> _run(String v) async {
    setState(() => _loading = true);
    try {
      final r = await SocialApi.find(v.trim().length < 2 ? '' : v);
      if (mounted && _q.text == v) setState(() => _r = r);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _list(String k) =>
      ((_r[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  bool get _browsing => _q.text.trim().length < 2;

  @override
  Widget build(BuildContext context) {
    final people = _filter == 2 ? <Map<String, dynamic>>[] : _list('people');
    final places = _filter == 1 ? <Map<String, dynamic>>[] : _list('places');
    final plans = _filter == 0 ? _list('plans') : <Map<String, dynamic>>[];
    final nothing = !_loading && people.isEmpty && places.isEmpty && plans.isEmpty;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        children: [
          Text('Search', style: B.display(32)),
          const SizedBox(height: 4),
          Text('People you know, places to go.', style: TextStyle(color: B.muted)),
          const SizedBox(height: 12),
          TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'A name, a bar, a place…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _loading
                  ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : (_q.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Clear',
                          onPressed: () {
                            _q.clear();
                            _run('');
                          })),
            ),
            onChanged: (v) {
              setState(() {});
              _changed(v);
            },
            onSubmitted: _run,
          ),
          const SizedBox(height: 10),
          Segmented(options: const ['Everything', 'People', 'Places'], index: _filter, onChanged: (i) => setState(() => _filter = i)),
          if (nothing)
            Padding(
              padding: const EdgeInsets.all(30),
              child: Center(
                child: Text(
                  _browsing
                      ? 'Nothing to suggest yet. As you make friends and save places, they\'ll show up here.'
                      : 'No one or nowhere by that name.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: B.muted),
                ),
              ),
            ),
          if (people.isNotEmpty) ...[
            _label(_browsing ? 'People you may know' : 'People'),
            for (final p in people) _person(p),
          ],
          if (places.isNotEmpty) ...[
            _label(_browsing ? 'Places your friends go' : 'Places'),
            for (final p in places) _place(p),
          ],
          if (plans.isNotEmpty) ...[
            _label(_browsing ? 'Your friends\' plans' : 'Plans'),
            for (final e in plans) _plan(e),
          ],
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 20, bottom: 6), child: SectionLabel(t));

  /// Why you might know them.
  String? _why(Map<String, dynamic> p) {
    final mutual = p['mutual'] as int? ?? 0;
    if (p['friendship'] == 'accepted') return 'Friend';
    final bits = <String>[
      if (p['friendship'] == 'pending') p['requested_by_me'] == true ? 'Request sent' : 'Wants to be friends',
      if (p['herd'] != null) 'In ${p['herd']}',
      if (mutual > 0) '$mutual mutual friend${mutual == 1 ? '' : 's'}',
    ];
    return bits.isEmpty ? null : bits.join(' · ');
  }

  Widget _person(Map<String, dynamic> p) {
    final why = _why(p);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: B.cardBox(),
      child: ListTile(
        leading: Avatar(path: p['photo'] as String?, size: 44),
        title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: why == null ? null : Text(why, style: TextStyle(color: p['friendship'] == 'accepted' ? B.goldInk : B.muted)),
        trailing: Icon(Icons.chevron_right, color: B.muted),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: p['id'] as String))),
      ),
    );
  }

  Widget _place(Map<String, dynamic> p) {
    final id = p['id'] as String;
    final saved = _saved[id] ?? (p['saved'] == true);
    final friends = p['friends_go'] as int? ?? 0;
    final here = p['here_now'] as int? ?? 0;
    final km = (p['km'] as num?)?.toDouble();
    final bits = <String>[
      if (here > 0) '$here here now',
      if (friends > 0) '$friends friend${friends == 1 ? '' : 's'} go${friends == 1 ? 'es' : ''} here',
      if (km != null && km < 9999) '${km.toStringAsFixed(km < 10 ? 1 : 0)} km',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: B.cardBox(border: p['featured'] == true ? const Color(0x99D9A84E) : null),
      child: Row(children: [
        Icon(p['partner'] == true ? Icons.local_bar : Icons.place_outlined, color: p['partner'] == true ? B.goldInk : B.ink2),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5))),
              if (p['partner'] == true) ...[
                const SizedBox(width: 6),
                Text('PARTNER', style: B.label.copyWith(color: B.goldInk, fontSize: 9.5)),
              ],
            ]),
            if (p['address'] != null)
              Text(p['address'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: B.muted, fontSize: 12.5)),
            if (bits.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(bits.join(' · '), style: TextStyle(color: here > 0 ? B.ok : B.ink2, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
        IconButton(
          tooltip: saved ? 'Remove from your spots' : 'Save to your spots',
          icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border, color: saved ? B.goldInk : B.muted),
          onPressed: () async {
            setState(() => _saved[id] = !saved);
            try {
              await PlacesApi.save(id, !saved);
            } catch (_) {
              if (mounted) setState(() => _saved[id] = saved);
            }
          },
        ),
        IconButton(
          tooltip: 'Directions',
          icon: Icon(Icons.directions_outlined, color: B.ink2),
          onPressed: () => PlacesApi.directions((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
        ),
      ]),
    );
  }

  Widget _plan(Map<String, dynamic> e) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: B.cardBox(),
        child: ListTile(
          leading: Icon(Icons.event, color: B.ink2),
          title: Text(e['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text([
            DateFormat('EEE, MMM d · h:mm a').format(DateTime.parse(e['starts_at'] as String).toLocal()),
            if (e['place'] != null) e['place'] as String,
            if (e['host'] != null) 'with ${e['host']}',
          ].join(' · ')),
          onTap: () => widget.openModule(3),
        ),
      );
}
