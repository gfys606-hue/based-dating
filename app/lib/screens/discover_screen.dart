import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/signed_photo.dart';
import '../widgets/ui.dart';
import 'feed_screen.dart';
import 'profile_view_screen.dart';

/// Discover: People (as Cards or on the Radar) or Posts.
/// Later this becomes the one search for everything (people, posts, products, places).
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.refresh, required this.mode});
  final ValueNotifier<int> refresh;
  final ValueNotifier<int> mode; // 0 people, 1 posts
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  late Future<List<Map<String, dynamic>>> _batch = Api.matchBatch();
  final List<String> _done = [];
  int _view = 0; // 0 cards, 1 radar

  @override
  void initState() {
    super.initState();
    widget.mode.addListener(_rebuild);
    widget.refresh.addListener(_reload);
  }

  @override
  void dispose() {
    widget.mode.removeListener(_rebuild);
    widget.refresh.removeListener(_reload);
    super.dispose();
  }

  void _rebuild() => setState(() {});
  void _reload() => setState(() { _done.clear(); _batch = Api.matchBatch(); });

  Future<void> _act(Map<String, dynamic> p, bool like) async {
    final id = p['user_id'] as String;
    setState(() => _done.add(id));
    try {
      if (like) {
        final match = await Api.like(id);
        if (match != null && mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
              title: Text("It's a match.", style: B.display(28), textAlign: TextAlign.center),
              content: Text('You and ${p['display_name']} have 3 days to get a 5-minute call in. Say hi in Talk.',
                  textAlign: TextAlign.center),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Nice')),
                ),
              ],
            ),
          );
        }
      } else {
        await Api.pass(id);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _openProfile(String userId) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: userId)),
      );

  @override
  Widget build(BuildContext context) {
    final posts = widget.mode.value == 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Discover', style: B.display(32)),
          const SizedBox(height: 12),
          Row(children: [
            PillChip(label: 'People', selected: !posts, onTap: () => widget.mode.value = 0),
            const SizedBox(width: 6),
            PillChip(label: 'Posts', selected: posts, onTap: () => widget.mode.value = 1),
            const Spacer(),
            if (!posts) Segmented(options: const ['Cards', 'Radar'], index: _view, onChanged: (i) => setState(() => _view = i)),
          ]),
        ]),
      ),
      Expanded(
        child: posts
            ? const PostsView()
            : FutureBuilder(
                future: _batch,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
                  final people = (snap.data ?? []).where((p) => !_done.contains(p['user_id'])).toList();
                  if (people.isEmpty) return _Empty(onRefresh: _reload);
                  return _view == 0
                      ? _Cards(person: people.first, left: people.length, onAct: _act, onOpen: _openProfile)
                      : _Radar(people: people, onOpen: _openProfile);
                },
              ),
      ),
    ]);
  }
}

class _Cards extends StatelessWidget {
  const _Cards({required this.person, required this.left, required this.onAct, required this.onOpen});
  final Map<String, dynamic> person;
  final int left;
  final Future<void> Function(Map<String, dynamic>, bool) onAct;
  final void Function(String) onOpen;

  String _block(int km) =>
      km <= 10 ? 'Within 10 km · shared interests first' : km <= 15 ? '10–15 km · closest first' : km <= 25 ? '15–25 km · closest first' : 'Up to ${km <= 50 ? 50 : km <= 100 ? 100 : 500} km';

  @override
  Widget build(BuildContext context) {
    final photos = List<String>.from(person['photo_paths'] ?? const []);
    final shared = List<String>.from(person['shared_topics'] ?? const []);
    final km = person['distance_km'] as int;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, B.navClearance),
      child: Column(children: [
        Expanded(
          child: GestureDetector(
            onTap: () => onOpen(person['user_id'] as String),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                boxShadow: [BoxShadow(color: B.ink.withOpacity(.35), blurRadius: 36, spreadRadius: -18, offset: const Offset(0, 16))],
              ),
              child: Stack(fit: StackFit.expand, children: [
                SignedPhoto(photos.isEmpty ? null : photos.first, radius: 26),
                Positioned(
                  top: 14,
                  left: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
                    child: Text(_block(km), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
                Positioned(
                  top: 14,
                  right: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: B.ink, borderRadius: BorderRadius.circular(999)),
                    child: Text('$left left today', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text('${person['display_name']}, ${person['age']}', style: B.display(24)),
                      const SizedBox(height: 3),
                      Text('$km km away', style: const TextStyle(color: B.muted)),
                      if (shared.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text('You both follow ${shared.take(3).join(', ')}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => onAct(person, false), child: const Text('Pass'))),
          const SizedBox(width: 10),
          Expanded(child: FilledButton(onPressed: () => onAct(person, true), child: const Text('Like'))),
        ]),
      ]),
    );
  }
}

/// Radar: rings at 10 / 15 / 25 / 50 km with people placed by distance.
class _Radar extends StatelessWidget {
  const _Radar({required this.people, required this.onOpen});
  final List<Map<String, dynamic>> people;
  final void Function(String) onOpen;

  static const _rings = [10, 15, 25, 50];

  /// Radius (as a fraction of the outer ring) for a distance in km.
  double _r(int km) {
    if (km <= 10) return .15 + km / 10 * .22; // inside 10 km ring (.38)
    if (km <= 15) return .40 + (km - 10) / 5 * .18; // up to .58
    if (km <= 25) return .60 + (km - 15) / 10 * .18; // up to .78
    return .82 + (math.min(km, 50) - 25) / 25 * .14; // up to .96
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, B.navClearance),
      children: [
        LayoutBuilder(builder: (context, c) {
          final size = c.maxWidth;
          final center = size / 2;
          return SizedBox(
            width: size,
            height: size,
            child: Stack(children: [
              CustomPaint(size: Size(size, size), painter: _RingsPainter()),
              for (var i = 0; i < _rings.length; i++)
                Positioned(
                  left: 0,
                  right: 0,
                  top: center - center * const [.38, .58, .78, .98][i] + 4,
                  child: Text('${_rings[i]} km',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: i == 1 ? const Color(0xFF8F3113) : B.muted)),
                ),
              Positioned(
                left: center - 22,
                top: center - 22,
                child: const CircleAvatar(
                    radius: 22, backgroundColor: B.ink, child: Text('You', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
              ),
              for (final p in people)
                Builder(builder: (_) {
                  final id = p['user_id'] as String;
                  // stable angle per person
                  final angle = (id.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0xffff) % 360) * math.pi / 180;
                  final r = _r(p['distance_km'] as int) * center;
                  final photos = List<String>.from(p['photo_paths'] ?? const []);
                  return Positioned(
                    left: center + r * math.cos(angle) - 22,
                    top: center + r * math.sin(angle) - 22,
                    child: Semantics(
                      button: true,
                      label: '${p['display_name']}, ${p['distance_km']} km',
                      child: GestureDetector(
                        onTap: () => onOpen(id),
                        child: Container(
                          width: 44,
                          height: 44,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: B.shadow),
                          child: SignedPhoto(photos.isEmpty ? null : photos.first, radius: 19),
                        ),
                      ),
                    ),
                  );
                }),
            ]),
          );
        }),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: B.cardBox(),
          child: const Text.rich(TextSpan(children: [
            TextSpan(text: 'Closest rings fill first. ', style: TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: 'Within 10 km, shared interests come first. Tap a face to see them.'),
          ]), style: TextStyle(color: B.ink2, height: 1.45)),
        ),
      ],
    );
  }
}

class _RingsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = B.line;
    canvas.drawCircle(c, r * .98, line);
    canvas.drawCircle(c, r * .78, line);
    canvas.drawCircle(c, r * .58, Paint()..color = B.accentSoft);
    canvas.drawCircle(c, r * .58, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFE6B8A4));
    canvas.drawCircle(c, r * .38, Paint()..color = Colors.white);
    canvas.drawCircle(c, r * .38, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = B.ink);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onRefresh});
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, B.navClearance),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text("That's everyone for today.", style: B.heading(22), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text('Talk to your matches. New people show up tomorrow, closest first.',
                textAlign: TextAlign.center, style: TextStyle(color: B.ink2)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRefresh, child: const Text('Refresh')),
          ]),
        ),
      );
}
