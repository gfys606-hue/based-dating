import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/signed_photo.dart';
import '../widgets/ui.dart';
import 'chat_screen.dart';

/// Home: "Your day". Everything that needs you comes first:
/// your next call, replies waiting on you, deadlines, then new people and posts.
/// (Future modules add their own cards here: orders, events, alerts.)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.refresh, required this.goTab});
  final ValueNotifier<int> refresh;
  final void Function(int tab, {int? discover}) goTab;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _matches = [];
  List<Map<String, dynamic>> _people = [];
  Map<String, dynamic>? _post;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        Api.myMatches(),
        Api.matchBatch(),
        Api.feed(range: 'region'),
      ]);
      if (!mounted) return;
      final posts = results[2].where((p) => p['author_id'] != Api.me).toList();
      setState(() {
        _matches = results[0];
        _people = results[1].take(3).toList();
        _post = posts.isEmpty ? null : posts.first;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openChat(Map<String, dynamic> m) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(match: m)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final open = _matches.where((m) => m['call_done'] != true).toList()
      ..sort((a, b) => hoursLeft(a).compareTo(hoursLeft(b)));
    final booked = _matches.where((m) => m['next_call_status'] == 'accepted' && m['call_done'] != true).toList()
      ..sort((a, b) => (a['next_call_at'] as String).compareTo(b['next_call_at'] as String));
    final hero = booked.isNotEmpty ? booked.first : (open.isNotEmpty ? open.first : null);

    final waiting = _matches.where((m) => m['last_message'] != null && m['last_from_me'] == false && m != hero).toList();
    final needs = <(Map<String, dynamic>, String?)>[
      for (final m in waiting.take(2)) (m, 'Replied. Your turn.'),
    ];
    for (final m in open) {
      if (needs.length >= 2) break;
      if (m != hero && !waiting.contains(m)) needs.add((m, null));
    }

    final now = DateTime.now();
    final partOfDay = now.hour < 12 ? 'morning' : now.hour < 17 ? 'afternoon' : 'evening';

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, B.navClearance),
        children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${DateFormat('EEEE').format(now)} $partOfDay', style: const TextStyle(color: B.muted, fontSize: 14)),
                Text('Your day', style: B.display(32)),
              ]),
            ),
            IconButton(
              tooltip: 'You',
              onPressed: () => widget.goTab(3),
              icon: const CircleAvatar(radius: 22, backgroundColor: Color(0xFFD9CDBD), child: Icon(Icons.person, color: B.ink2)),
            ),
          ]),
          const SizedBox(height: 16),

          if (_loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),

          if (hero != null) ...[
            _HeroCard(match: hero, onTap: () => _openChat(hero)),
            const SizedBox(height: 18),
          ],

          if (needs.isNotEmpty) ...[
            const SectionLabel('Needs you'),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.05,
              children: [for (final n in needs) TimerTile(match: n.$1, caption: n.$2, onTap: () => _openChat(n.$1))],
            ),
            const SizedBox(height: 18),
          ],

          Row(children: [
            Expanded(child: Text('New near you', style: B.heading(18))),
            TextButton(onPressed: () => widget.goTab(1, discover: 0), child: const Text('See all')),
          ]),
          const SizedBox(height: 6),
          if (_people.isEmpty && !_loading)
            const Text("You've seen everyone for today. More tomorrow.", style: TextStyle(color: B.muted)),
          if (_people.isNotEmpty)
            Row(children: [
              for (var i = 0; i < _people.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: _PersonTile(person: _people[i], onTap: () => widget.goTab(1, discover: 0))),
              ],
            ]),

          if (_post != null) ...[
            const SizedBox(height: 20),
            Text('From people near you', style: B.heading(18)),
            const SizedBox(height: 10),
            InkWell(
              onTap: () => widget.goTab(1, discover: 1),
              borderRadius: BorderRadius.circular(B.radius),
              child: Ink(
                padding: const EdgeInsets.all(14),
                decoration: B.cardBox(),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Avatar(path: _post!['author_photo'] as String?, size: 32),
                    const SizedBox(width: 10),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_post!['author_name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${_post!['topic']}${_post!['distance_km'] == null ? '' : ' · ${_post!['distance_km']} km'}',
                          style: const TextStyle(fontSize: 12, color: B.muted)),
                    ]),
                  ]),
                  const SizedBox(height: 8),
                  Text(_post!['body'] as String? ?? '', style: const TextStyle(fontSize: 15, height: 1.4)),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.match, required this.onTap});
  final Map<String, dynamic> match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final booked = match['next_call_status'] == 'accepted';
    final when = booked ? DateTime.parse(match['next_call_at'] as String).toLocal() : null;
    final kicker = booked
        ? '${match['next_call_kind'] == 'video' ? 'VIDEO' : 'VOICE'} CALL · ${DateFormat('EEE h:mm a').format(when!).toUpperCase()}'
        : '${timeLeftLabel(hoursLeft(match)).toUpperCase()} LEFT';
    final title = booked ? 'Call with ${match['other_name']}' : 'Book a call with ${match['other_name']}';
    final sub = booked ? 'Be there. No-shows count against you.' : '5 minutes is enough to know.';

    return Material(
      color: B.ink,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            SizedBox(width: 72, height: 88, child: SignedPhoto(match['other_photo'] as String?, radius: 16)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(kicker, style: const TextStyle(color: Color(0xFFF0A58A), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: .6)),
                const SizedBox(height: 2),
                Text(title, style: B.heading(19).copyWith(color: Colors.white)),
                const SizedBox(height: 2),
                Text(sub, style: const TextStyle(color: Color(0xFFBDB8B0), fontSize: 13)),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: B.accent, borderRadius: BorderRadius.circular(14)),
              child: Text(booked ? 'Open' : 'Book', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person, required this.onTap});
  final Map<String, dynamic> person;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final photos = List<String>.from(person['photo_paths'] ?? const []);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 132,
        child: Stack(fit: StackFit.expand, children: [
          SignedPhoto(photos.isEmpty ? null : photos.first, radius: 18),
          Positioned(
            left: 8,
            bottom: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: Text('${person['display_name']} · ${person['distance_km']} km',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }
}
