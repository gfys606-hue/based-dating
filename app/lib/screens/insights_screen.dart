import 'package:flutter/material.dart';

import '../services/rooms_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Owner only: who's joining, what they're into, and what kinds of people connect. Aggregates, never individuals.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});
  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  Map<String, dynamic>? _d;
  bool _test = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await RoomsApi.insights(includeTest: _test);
      if (mounted) setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t load insights.');
    }
  }

  List<Map<String, dynamic>> _list(dynamic v) =>
      List<Map<String, dynamic>>.from(((v as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

  Widget _bars(String title, List<Map<String, dynamic>> rows, {String empty = 'Nothing yet.'}) {
    final max = rows.fold<int>(1, (m, r) => (r['n'] as num).toInt() > m ? (r['n'] as num).toInt() : m);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionLabel(title),
        const SizedBox(height: 8),
        if (rows.isEmpty) Text(empty, style: TextStyle(color: B.muted)),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              SizedBox(width: 130, child: Text(r['label'] as String, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (r['n'] as num) / max,
                    minHeight: 10,
                    color: B.accent,
                    backgroundColor: B.fill,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: Text(
                  r['before'] == null ? '${r['n']}' : '${r['n']} (was ${r['before']})',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final s = d == null ? null : Map<String, dynamic>.from(d['signups'] as Map);
    final i = d == null ? null : Map<String, dynamic>.from(d['interests'] as Map);
    final f = d == null ? null : Map<String, dynamic>.from(d['funnel'] as Map);
    final c = d == null ? null : Map<String, dynamic>.from(d['connect_most'] as Map);
    return Scaffold(
      appBar: AppBar(title: Text('Insights', style: B.heading(22))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _test,
            title: const Text('Include test profiles'),
            subtitle: const Text('Off: real members only.'),
            onChanged: (v) {
              setState(() => _test = v);
              _load();
            },
          ),
          if (d == null)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: TextStyle(color: B.muted))),
            )
          else ...[
            Text('${d['city']} · ${s!['total']} members · ${s['last_30d']} joined in the last 30 days',
                style: TextStyle(color: B.ink2, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            const SectionLabel('Connection funnel · last 30 days'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in [
                ('Matches', f!['matches']),
                ('Voice swaps', f['voice_swaps']),
                ('Same-room meets', f['room_meets']),
                ('Friendships', f['friendships']),
              ])
                Container(
                  width: 150,
                  padding: const EdgeInsets.all(12),
                  decoration: B.cardBox(),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e.$2}', style: B.display(28)),
                    Text(e.$1, style: TextStyle(color: B.muted, fontSize: 12.5)),
                  ]),
                ),
            ]),
            const SizedBox(height: 20),
            _bars('Joined from', _list(s['by_source'])),
            _bars('Ages', _list(s['by_age'])),
            _bars('Cities', _list(s['by_city'])),
            _bars('Top interests in ${d['city']}', _list(i!['top'])),
            _bars('Growing interests (new members, 30 days)', _list(i['growing'])),
            _bars('Interests shared by people who connected', _list(c!['topics']),
                empty: 'No one has connected yet (a voice swap on Ouch, or becoming friends).'),
            _bars('Interest pairs that connect most', _list(c['combos'])),
            Text('Counts only. Nothing here shows what any one person did.', style: TextStyle(color: B.muted, fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}
