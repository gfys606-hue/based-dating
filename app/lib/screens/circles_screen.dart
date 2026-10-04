import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/friends_api.dart';
import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/live_chat.dart';
import '../widgets/ui.dart';
import 'events_screen.dart';
import 'profile_view_screen.dart';

/// Circles: groups of up to 30 that run themselves. Anyone can start one; members bring people in
/// by nominating them, and an invite goes out once enough members say yes.
class CirclesScreen extends StatefulWidget {
  const CirclesScreen({super.key});
  @override
  State<CirclesScreen> createState() => _CirclesScreenState();
}

class _CirclesScreenState extends State<CirclesScreen> {
  List<Map<String, dynamic>> _circles = [];
  List<Map<String, dynamic>> _invites = [];
  bool _loading = true;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await SocialApi.myCircles();
      final inv = await SocialApi.circleInvites().catchError((_) => <Map<String, dynamic>>[]);
      if (mounted) setState(() { _circles = c; _invites = inv; _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Couldn\'t load your herds.'; });
    }
  }

  Future<void> _start() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start a herd'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: name,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'e.g. Thursday regulars'),
          ),
          Text('You\'ll be the first member. Bring people in by nominating them.',
              style: TextStyle(color: B.muted, fontSize: 12.5)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('START')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    setState(() => _starting = true);
    try {
      final id = await SocialApi.createCircle(name.text.trim());
      await _load();
      final c = _circles.firstWhere((x) => x['circle_id'] == id, orElse: () => {'circle_id': id, 'name': name.text.trim()});
      if (mounted) await _openCircle(c);
    } catch (e) {
      if (mounted) {
        final m = (e.toString().contains('10 herds') || e.toString().contains('10 circles')) ? 'You\'re in 10 herds already. Leave one to start another.' : 'Couldn\'t start it. Try again.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _answer(Map<String, dynamic> inv, bool accept) async {
    try {
      await SocialApi.answerCircleInvite(inv['nomination_id'] as String, accept);
      await _load();
      if (accept && mounted) {
        final c = _circles.firstWhere((x) => x['circle_id'] == inv['circle_id'], orElse: () => {'circle_id': inv['circle_id'], 'name': inv['name']});
        await _openCircle(c);
      }
    } catch (e) {
      if (mounted) {
        final m = e.toString().contains('full') ? 'That herd is full right now.' : 'Couldn\'t do that. Try again.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
      }
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
            Text('Herd', style: B.display(32)),
            const SizedBox(height: 6),
            Text('Your herd, by invitation. Members decide together who comes in.',
                style: TextStyle(color: B.ink2, height: 1.4)),
            const SizedBox(height: 18),
            if (_invites.isNotEmpty) ...[
              SectionLabel('You\'re invited', color: B.accentStrong),
              const SizedBox(height: 10),
              for (final inv in _invites) _inviteTile(inv),
              const SizedBox(height: 14),
            ],
            _startCard(),
            const SizedBox(height: 22),
            if (_loading)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Text(_error!, style: TextStyle(color: B.urgent))
            else if (_circles.isNotEmpty) ...[
              const SectionLabel('Your herds'),
              const SizedBox(height: 10),
              for (final c in _circles) _circleTile(c),
            ],
          ],
        ),
      ),
    );
  }

  Widget _inviteTile(Map<String, dynamic> inv) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: B.cardBox(border: const Color(0x99F5C542)),
          child: Row(children: [
            const Icon(Icons.vpn_key, color: B.gold),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(inv['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                Text('${inv['members']} ${inv['members'] == 1 ? 'member' : 'members'}${inv['topic'] == null ? '' : ' · ${inv['topic']}'}',
                    style: TextStyle(color: B.muted, fontSize: 13)),
              ]),
            ),
            TextButton(onPressed: () => _answer(inv, false), child: const Text('Not now')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
              onPressed: () => _answer(inv, true),
              child: const Text('JOIN'),
            ),
          ]),
        ),
      );

  Widget _startCard() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(B.radius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_circles.isEmpty ? 'Start your herd' : 'Start another herd', style: B.heading(20).copyWith(color: Colors.white)),
          const SizedBox(height: 4),
          Text('Name it, then nominate the people you want in. Your herd votes on everyone after that.',
              style: TextStyle(color: B.onPanelMuted, height: 1.4)),
          const SizedBox(height: 14),
          FilledButton(onPressed: _starting ? null : _start, child: Text(_starting ? 'Starting…' : 'START A HERD')),
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
              decoration: BoxDecoration(color: B.accentSoft, borderRadius: BorderRadius.circular(3)),
              child: Text('${c['member_count'] ?? ''}', style: B.heading(18).copyWith(color: B.accent)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
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
        title: const Text('Leave this herd?'),
        content: const Text('To come back later, a member of the herd would need to nominate you again.'),
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
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.circle['name'] as String? ?? 'Herd'),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'leave') _leave();
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'leave', child: Text('Leave herd'))],
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Chat'), Tab(text: 'Plans'), Tab(text: 'Grow')]),
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
                    child: GestureDetector(
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: m['user_id'] as String))),
                      child: Column(children: [
                        Avatar(path: m['photo'] as String?, size: 48),
                        const SizedBox(height: 4),
                        Text(m['name'] as String, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      ]),
                    ),
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
                hint: 'Message the herd',
              ),
              EventsList(circleId: _id),
              _GrowTab(circleId: _id, memberIds: _members.map((m) => m['user_id'] as String).toSet()),
            ]),
          ),
        ]),
      ),
    );
  }
}


/// Grow: vote on nominations, see suggested people, and nominate someone.
/// The person being considered never sees any of this.
class _GrowTab extends StatefulWidget {
  const _GrowTab({required this.circleId, required this.memberIds});
  final String circleId;
  final Set<String> memberIds;
  @override
  State<_GrowTab> createState() => _GrowTabState();
}

class _GrowTabState extends State<_GrowTab> {
  List<Map<String, dynamic>> _noms = [];
  List<Map<String, dynamic>> _cands = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([SocialApi.nominations(widget.circleId), SocialApi.candidates(widget.circleId)]);
      if (mounted) setState(() { _noms = r[0]; _cands = r[1]; });
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _nominate(String userId, String name) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Nominate $name?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('The herd votes. If enough say yes, $name gets an invite. They never see the vote.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 10),
          TextField(controller: note, maxLength: 200, decoration: const InputDecoration(hintText: 'Why? (optional, members only)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('NOMINATE')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final st = await SocialApi.nominate(widget.circleId, userId, note: note.text.trim().isEmpty ? null : note.text.trim());
      _toast(st == 'invited' ? 'That was enough votes. $name has been invited.' : 'Nominated. The herd will vote.');
    } catch (e) {
      final s = e.toString();
      _toast(s.contains('recently')
          ? 'They were considered recently. Try again later.'
          : s.contains('Already')
              ? 'Already nominated.'
              : s.contains('a lot')
                  ? 'That\'s a lot of nominations today. Try tomorrow.'
                  : 'Couldn\'t nominate them.');
    }
    _load();
  }

  Future<void> _pickFriend() async {
    final friends = (await FriendsApi.friends().catchError((_) => <Map<String, dynamic>>[]))
        .where((f) => !widget.memberIds.contains(f['user_id']))
        .toList();
    if (!mounted) return;
    final f = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          Text('Nominate a friend', style: B.heading(22)),
          const SizedBox(height: 6),
          if (friends.isEmpty) Text('All your friends are already in, or you haven\'t added any yet.', style: TextStyle(color: B.muted)),
          for (final f in friends)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Avatar(path: f['photo'] as String?, size: 38),
              title: Text(f['name'] as String),
              onTap: () => Navigator.pop(ctx, f),
            ),
        ]),
      ),
    );
    if (f != null) _nominate(f['user_id'] as String, f['name'] as String);
  }

  Future<void> _vote(Map<String, dynamic> n, bool yes) async {
    try {
      final st = await SocialApi.vote(n['nomination_id'] as String, yes);
      if (st == 'invited') _toast('${n['name']} has been invited.');
    } catch (_) {
      _toast('Vote didn\'t go through. Try again.');
    }
    _load();
  }

  String _statusText(Map<String, dynamic> n) => switch (n['status']) {
        'invited' => 'Invited · waiting on them',
        'joined' => 'Joined',
        'declined' => 'Said no thanks',
        'not_enough' => 'Not enough votes',
        'expired' => 'Expired',
        _ => '${n['yes']} of ${n['needed']} yes votes · closes ${DateFormat('EEE').format(DateTime.parse(n['closes_at'] as String).toLocal())}',
      };

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final voting = _noms.where((n) => n['status'] == 'voting').toList();
    final done = _noms.where((n) => n['status'] != 'voting').toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        OutlinedButton.icon(onPressed: _pickFriend, icon: const Icon(Icons.person_add_alt_1), label: const Text('NOMINATE A FRIEND')),
        const SizedBox(height: 6),
        Text('Someone gets in when 25% of the herd plus 1 say yes. Nobody can veto, and the person never sees the vote.',
            style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 18),
        if (voting.isNotEmpty) ...[
          SectionLabel('Your vote', color: B.accentStrong),
          const SizedBox(height: 8),
          for (final n in voting) _nomCard(n),
          const SizedBox(height: 14),
        ],
        if (_cands.isNotEmpty) ...[
          const SectionLabel('People your herd might want'),
          const SizedBox(height: 8),
          for (final c in _cands)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: c['user_id'] as String))),
                child: Avatar(path: c['photo'] as String?, size: 42),
              ),
              title: Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                ...List<String>.from(c['reasons'] as List? ?? const []),
                if (c['distance_km'] != null) '${c['distance_km']} km',
              ].join(' · ')),
              trailing: TextButton(onPressed: () => _nominate(c['user_id'] as String, c['name'] as String), child: const Text('NOMINATE')),
            ),
          const SizedBox(height: 14),
        ],
        if (done.isNotEmpty) ...[
          const SectionLabel('Recent'),
          for (final n in done)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Avatar(path: n['photo'] as String?, size: 36),
              title: Text(n['name'] as String),
              subtitle: Text(_statusText(n)),
            ),
        ],
      ]),
    );
  }

  Widget _nomCard(Map<String, dynamic> n) {
    final mine = n['my_vote'] as bool?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: B.cardBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: n['user_id'] as String))),
              child: Avatar(path: n['photo'] as String?, size: 46),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                Text('Nominated by ${n['nominated_by'] ?? 'a member'}', style: TextStyle(color: B.muted, fontSize: 12.5)),
                Text(_statusText(n), style: TextStyle(color: B.accentStrong, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
          if (n['note'] != null) ...[
            const SizedBox(height: 8),
            Text('"${n['note']}"', style: const TextStyle(fontStyle: FontStyle.italic)),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _vote(n, false),
                style: OutlinedButton.styleFrom(backgroundColor: mine == false ? B.fill : null),
                child: Text(mine == false ? 'NO ✓' : 'NO'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: () => _vote(n, true),
                child: Text(mine == true ? 'YES ✓' : 'YES'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
