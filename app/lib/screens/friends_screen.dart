import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/friends_api.dart';
import '../theme.dart';
import '../widgets/friend_button.dart';
import '../widgets/live_chat.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// Friends: people you've met and added. Requests on top, then your inner circle, then everyone else.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, required this.refresh, this.onChanged});
  final ValueNotifier<int> refresh;
  final VoidCallback? onChanged;
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  List<Map<String, dynamic>> _friends = [];
  List<Map<String, dynamic>> _requests = [];
  bool _loading = true;
  String _query = '';

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
      final r = await Future.wait([FriendsApi.friends(), FriendsApi.requests()]);
      if (mounted) {
        setState(() {
          _friends = r[0];
          _requests = r[1];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    widget.onChanged?.call();
  }

  Future<void> _respond(Map<String, dynamic> r, bool accept) async {
    try {
      await FriendsApi.respond(r['user_id'] as String, accept);
    } catch (_) {}
    _load();
  }

  Future<void> _open(Map<String, dynamic> f) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FriendChatScreen(friend: f)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty ? _friends : _friends.where((f) => (f['name'] as String).toLowerCase().contains(q)).toList();
    final inner = shown.where((f) => f['is_inner'] == true).toList();
    final rest = shown.where((f) => f['is_inner'] != true).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, B.navClearance),
        children: [
          Row(children: [
            Expanded(child: Text('Friends', style: B.display(32))),
            IconButton(
              tooltip: 'What friends can see',
              icon: const Icon(Icons.visibility_outlined),
              onPressed: () => showFriendVisibilitySheet(context),
            ),
          ]),
          const SizedBox(height: 4),
          Text('People you\'ve met. Add someone from their profile.', style: TextStyle(color: B.muted, fontSize: 13)),
          const SizedBox(height: 14),
          if (_friends.length > 6)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Find a friend'),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          if (_loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          if (_requests.isNotEmpty) ...[
            SectionLabel('Requests', color: B.accentStrong),
            const SizedBox(height: 10),
            for (final r in _requests) _requestTile(r),
            const SizedBox(height: 14),
          ],
          if (inner.isNotEmpty) ...[
            SectionLabel('Inner circle', color: B.accentStrong),
            const SizedBox(height: 10),
            for (final f in inner) _friendTile(f),
            const SizedBox(height: 14),
          ],
          if (rest.isNotEmpty) ...[
            const SectionLabel('Friends'),
            const SizedBox(height: 10),
            for (final f in rest) _friendTile(f),
          ],
          if (!_loading && _friends.isEmpty && _requests.isEmpty)
            Container(
              padding: const EdgeInsets.all(28),
              decoration: B.cardBox(),
              child: Text(
                'No friends yet. After you\'ve talked to a match, or met someone in a circle or at an event, '
                'open their profile and tap Add friend.',
                textAlign: TextAlign.center,
                style: TextStyle(color: B.muted, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _requestTile(Map<String, dynamic> r) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: B.cardBox(),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: r['user_id'] as String))),
              child: Avatar(path: r['photo'] as String?, size: 46),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                if (r['met'] != null) Text(r['met'] as String, style: TextStyle(color: B.muted, fontSize: 12.5)),
              ]),
            ),
            TextButton(onPressed: () => _respond(r, false), child: const Text('Not now')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
              onPressed: () => _respond(r, true),
              child: const Text('ACCEPT'),
            ),
          ]),
        ),
      );

  Widget _friendTile(Map<String, dynamic> f) {
    final plans = (f['plans'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final circles = (f['circles'] as List?)?.cast<String>();
    final lines = <String>[
      if (plans != null && plans.isNotEmpty)
        'Going to ${plans.first['title']} · ${DateFormat('EEE h:mm a').format(DateTime.parse(plans.first['starts_at'] as String).toLocal())}',
      if (circles != null && circles.isNotEmpty) 'In ${circles.join(', ')}',
    ];
    final last = f['last_message'] as String?;
    final unread = last != null && f['last_from_me'] == false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _open(f),
        borderRadius: BorderRadius.circular(B.radius),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: B.cardBox(border: f['is_inner'] == true ? const Color(0x99F5C542) : null),
          child: Row(children: [
            Avatar(path: f['photo'] as String?, size: 50),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(f['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                  if (f['is_inner'] == true) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.star, size: 15, color: B.gold),
                  ],
                ]),
                for (final l in lines)
                  Text(l, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: B.accentStrong, fontSize: 12.5, fontWeight: FontWeight.w600)),
                Text(
                  last ?? 'Say hi',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: unread ? B.ink : B.muted, fontSize: 13, fontWeight: unread ? FontWeight.w700 : FontWeight.w400),
                ),
              ]),
            ),
            if (unread) Container(width: 9, height: 9, decoration: const BoxDecoration(color: B.gold, shape: BoxShape.circle)),
          ]),
        ),
      ),
    );
  }
}

/// Chat with a friend. The app bar opens their profile (where you manage friend / inner circle).
class FriendChatScreen extends StatelessWidget {
  const FriendChatScreen({super.key, required this.friend});
  final Map<String, dynamic> friend;

  @override
  Widget build(BuildContext context) {
    final id = friend['user_id'] as String;
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: id))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Avatar(path: friend['photo'] as String?, size: 34),
            const SizedBox(width: 10),
            Text(friend['name'] as String, style: B.heading(20)),
            if (friend['is_inner'] == true) ...[
              const SizedBox(width: 6),
              const Icon(Icons.star, size: 16, color: B.gold),
            ],
          ]),
        ),
        actions: [
          IconButton(
            tooltip: 'Friend settings',
            icon: const Icon(Icons.more_horiz),
            onPressed: () => showModalBottomSheet(
              context: context,
              builder: (_) => SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: FriendButton(userId: id, name: friend['name'] as String),
                ),
              ),
            ),
          ),
        ],
      ),
      body: LiveChat(
        stream: FriendsApi.messages(friend['friendship_id'] as String),
        onSend: (b) => FriendsApi.send(friend['friendship_id'] as String, b),
        hint: 'Message ${friend['name']}',
      ),
    );
  }
}

/// "What friends can see": inner circle always sees everything; this sets what other friends see.
Future<void> showFriendVisibilitySheet(BuildContext context) async {
  Map<String, dynamic> v;
  try {
    v = await FriendsApi.visibility();
  } catch (_) {
    v = {};
  }
  if (!context.mounted) return;
  var plans = v['plans'] == true;
  var circles = v['circles'] == true;
  await showModalBottomSheet(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('What friends can see', style: B.heading(24)),
            const SizedBox(height: 6),
            Text('Your inner circle always sees everything. These switches are for everyone else on your friends list.',
                style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: plans,
              title: const Text('My plans'),
              subtitle: const Text('Events I\'m going to'),
              onChanged: (x) => set(() => plans = x),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: circles,
              title: const Text('My circles'),
              subtitle: const Text('Which circles I\'m in'),
              onChanged: (x) => set(() => circles = x),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  try {
                    await FriendsApi.setVisibility(plans: plans, circles: circles);
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('SAVE'),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}
