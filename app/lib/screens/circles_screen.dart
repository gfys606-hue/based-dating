import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/live_chat.dart';
import '../widgets/ui.dart';
import 'events_screen.dart';

/// Circles: small groups (up to 8) of people who fit together:
/// shared interests, overlapping free time, and nearby. Based places you; you just show up.
class CirclesScreen extends StatefulWidget {
  const CirclesScreen({super.key});
  @override
  State<CirclesScreen> createState() => _CirclesScreenState();
}

class _CirclesScreenState extends State<CirclesScreen> {
  List<Map<String, dynamic>> _circles = [];
  bool _loading = true;
  bool _finding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await SocialApi.myCircles();
      if (mounted) setState(() { _circles = c; _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Couldn\'t load your circles.'; });
    }
  }

  Future<void> _find() async {
    setState(() => _finding = true);
    try {
      final id = await SocialApi.findMyCircle();
      await _load();
      final c = _circles.firstWhere((x) => x['circle_id'] == id, orElse: () => {'circle_id': id, 'name': 'Your circle'});
      if (mounted) await _openCircle(c);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn\'t find a circle right now. Add a few interests and try again.')));
      }
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  Future<void> _openCircle(Map<String, dynamic> c) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CircleScreen(circle: c)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
          children: [
            Text('Circles', style: B.display(32)),
            const SizedBox(height: 6),
            Text('Small groups of people you\'d actually get along with. Placed by what you\'re into, when you\'re free, and where you are.',
                style: TextStyle(color: B.ink2, height: 1.4)),
            const SizedBox(height: 18),
            _findCard(),
            const SizedBox(height: 22),
            if (_loading)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Text(_error!, style: TextStyle(color: B.urgent))
            else if (_circles.isNotEmpty) ...[
              const SectionLabel('Your circles'),
              const SizedBox(height: 10),
              for (final c in _circles) _circleTile(c),
            ],
          ],
        ),
      ),
    );
  }

  Widget _findCard() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(B.radius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            for (var i = 0; i < 4; i++)
              Align(
                widthFactor: .7,
                child: CircleAvatar(radius: 16, backgroundColor: [B.accent, B.panelAccent, const Color(0xFF6E8B74), const Color(0xFF9BA0A7)][i]),
              ),
          ]),
          const SizedBox(height: 14),
          Text(_circles.isEmpty ? 'Find your circle' : 'Find another circle', style: B.heading(20).copyWith(color: Colors.white)),
          const SizedBox(height: 4),
          const Text('We\'ll put you with people nearby who share your interests and free time.',
              style: TextStyle(color: Colors.white70, height: 1.4)),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _finding ? null : _find,
            child: Text(_finding ? 'Finding…' : 'Place me'),
          ),
        ]),
      );

  Widget _circleTile(Map<String, dynamic> c) {
    final last = c['last_message'] as String?;
    final at = c['last_message_at'] as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(B.radius),
        onTap: () => _openCircle(c),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: B.cardBox(),
          child: Row(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: B.accentSoft, borderRadius: BorderRadius.circular(8)),
              child: Text('${c['member_count'] ?? ''}', style: B.heading(18).copyWith(color: B.accent)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 2),
                Text(last ?? '${c['member_count']} members · say hi',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: B.muted, fontSize: 13)),
              ]),
            ),
            if (at != null)
              Text(DateFormat.MMMd().format(DateTime.parse(at).toLocal()), style: TextStyle(color: B.muted, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// One circle: who's in it, group chat, and plans.
class CircleScreen extends StatefulWidget {
  const CircleScreen({super.key, required this.circle});
  final Map<String, dynamic> circle;
  @override
  State<CircleScreen> createState() => _CircleScreenState();
}

class _CircleScreenState extends State<CircleScreen> {
  List<Map<String, dynamic>> _members = [];
  String get _id => widget.circle['circle_id'] as String;

  @override
  void initState() {
    super.initState();
    SocialApi.circleMembers(_id).then((m) {
      if (mounted) setState(() => _members = m);
    }).catchError((_) {});
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave this circle?'),
        content: const Text('You can always find a new one.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;
    await SocialApi.leaveCircle(_id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final names = {for (final m in _members) m['user_id'] as String: m['name'] as String};
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.circle['name'] as String? ?? 'Circle'),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'leave') _leave();
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'leave', child: Text('Leave circle'))],
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Chat'), Tab(text: 'Plans')]),
        ),
        body: Column(children: [
          SizedBox(
            height: 92,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              children: [
                for (final m in _members)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(children: [
                      Avatar(path: m['photo'] as String?, size: 48),
                      const SizedBox(height: 4),
                      Text(m['name'] as String, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(children: [
              LiveChat(
                stream: SocialApi.circleMessages(_id),
                onSend: (b) => SocialApi.sendCircleMessage(_id, b),
                names: names,
                showNames: true,
                hint: 'Message the circle',
              ),
              EventsList(circleId: _id),
            ]),
          ),
        ]),
      ),
    );
  }
}
