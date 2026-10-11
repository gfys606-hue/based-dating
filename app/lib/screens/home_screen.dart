import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../services/city_api.dart';
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
  bool _datingOn = false;
  Map<String, dynamic>? _post;
  List<Map<String, dynamic>> _notices = [];
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
    CityApi.mine().catchError((_) => null);
    try {
      final results = await Future.wait([
        Api.myMatches(),
        Api.matchBatch(),
        Api.feed(range: 'region'),
        Api.unreadNotices().catchError((_) => <Map<String, dynamic>>[]),
        Api.myProfile().then((p) => p == null ? <Map<String, dynamic>>[] : [p]).catchError((_) => <Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      final posts = results[2].where((p) => p['author_id'] != Api.me).toList();
      setState(() {
        _matches = results[0];
        _people = results[1].take(3).toList();
        _post = posts.isEmpty ? null : posts.first;
        _notices = results[3];
        _datingOn = results[4].isNotEmpty && results[4].first['dating_on'] == true;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _dismissNotices() async {
    final ids = [for (final n in _notices) n['id'] as int];
    setState(() => _notices = []);
    try {
      await Api.markNoticesRead(ids);
    } catch (_) {}
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
                Text('The door is not for everyone.', style: B.sloganStyle),
                // the city you're meeting people in (pick it in Edit profile)
                ValueListenableBuilder(
                  valueListenable: CityApi.current,
                  builder: (context, city, _) => city == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Row(children: [
                            Icon(Icons.place_outlined, size: 13, color: B.goldInk),
                            const SizedBox(width: 4),
                            Text((city['name'] as String).toUpperCase(), style: B.label.copyWith(color: B.goldInk)),
                          ]),
                        ),
                ),
                const SizedBox(height: 8),
                Text('${DateFormat('EEEE').format(now)} $partOfDay'.toUpperCase(), style: B.label),
                const SizedBox(height: 4),
                Text(now.hour >= 17 ? 'Your evening' : 'Your day', style: B.display(34)),
              ]),
            ),
            IconButton(
              tooltip: 'You',
              onPressed: () => widget.goTab(3),
              icon: CircleAvatar(radius: 22, backgroundColor: B.avatarFill, child: Icon(Icons.person, color: B.ink2)),
            ),
          ]),
          const SizedBox(height: 16),

          if (_loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),

          if (_notices.isNotEmpty) ...[
            _NoticesCard(notices: _notices, onDismiss: _dismissNotices),
            const SizedBox(height: 18),
          ],

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

          if (_datingOn) ...[
          Row(children: [
            Expanded(child: Text('New near you', style: B.heading(18))),
            TextButton(onPressed: () => widget.goTab(1, discover: 0), child: const Text('See all')),
          ]),
          const SizedBox(height: 6),
          if (_people.isEmpty && !_loading)
            Text("You've seen everyone for today. More tomorrow.", style: TextStyle(color: B.muted)),
          if (_people.isNotEmpty)
            Row(children: [
              for (var i = 0; i < _people.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: _PersonTile(person: _people[i], onTap: () => widget.goTab(1, discover: 0))),
              ],
            ]),
          ],

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
                          style: TextStyle(fontSize: 12, color: B.muted)),
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

/// Things the app needs you to know: nudges, missed calls, blocked messages, expiries.
class _NoticesCard extends StatelessWidget {
  const _NoticesCard({required this.notices, required this.onDismiss});
  final List<Map<String, dynamic>> notices;
  final VoidCallback onDismiss;

  static IconData _icon(String kind) => switch (kind) {
        'nudge' => Icons.visibility_outlined,
        'no_show' || 'call_missed' => Icons.phone_missed,
        'message_blocked' => Icons.block,
        'match_expired' || 'match_ended' => Icons.hourglass_bottom,
        'match' => Icons.favorite,
        'paused' => Icons.pause_circle_outline,
        'contact_unlocked' => Icons.lock_open,
        _ => Icons.notifications_none,
      };

  @override
  Widget build(BuildContext context) {
    final shown = notices.take(4).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
      decoration: BoxDecoration(color: B.accentSoft, borderRadius: BorderRadius.circular(B.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionLabel('Heads up'),
        const SizedBox(height: 6),
        for (final n in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, right: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(_icon(n['kind'] as String? ?? ''), size: 18, color: B.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(n['body'] as String? ?? '', style: TextStyle(fontSize: 14, height: 1.35, color: B.ink))),
            ]),
          ),
        Row(children: [
          if (notices.length > shown.length)
            Text('+${notices.length - shown.length} more', style: TextStyle(fontSize: 12, color: B.muted)),
          const Spacer(),
          TextButton(onPressed: onDismiss, child: const Text('Got it')),
        ]),
      ]),
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
      color: B.hero,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            SizedBox(width: 72, height: 88, child: SignedPhoto(match['other_photo'] as String?, radius: 16)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(kicker, style: const TextStyle(color: B.panelAccent, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: .6)),
                const SizedBox(height: 2),
                Text(title, style: B.heading(19).copyWith(color: Colors.white)),
                const SizedBox(height: 2),
                Text(sub, style: const TextStyle(color: Color(0xFFE9D9BE), fontSize: 13)),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: B.gold, borderRadius: BorderRadius.circular(2)),
              child: Text(booked ? 'OPEN' : 'BOOK', style: const TextStyle(color: B.onGold, fontWeight: FontWeight.w700, letterSpacing: 1.4, fontSize: 12.5)),
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
              decoration: BoxDecoration(color: B.card, borderRadius: BorderRadius.circular(2)),
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
