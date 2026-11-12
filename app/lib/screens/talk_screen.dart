import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/friends_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'chat_screen.dart';
import 'friends_screen.dart' show FriendChatScreen;

/// Talk: one inbox. Matches that still need a call sit on top as timer tiles, then every
/// conversation — dating matches and friends both, newest message first. (Later: sellers and
/// groups share this same inbox.)
class TalkScreen extends StatefulWidget {
  const TalkScreen({super.key, required this.refresh, this.onChanged});
  final ValueNotifier<int> refresh;
  final VoidCallback? onChanged;
  @override
  State<TalkScreen> createState() => _TalkScreenState();
}

/// One row in the inbox, however it got here.
class _Convo {
  _Convo.match(this.raw)
      : kind = 'match',
        name = raw['other_name'] as String,
        photo = raw['other_photo'] as String?,
        lastMessage = raw['last_message'] as String?,
        lastFromMe = raw['last_from_me'] == true,
        at = DateTime.parse((raw['last_message_at'] ?? raw['created_at']) as String);

  _Convo.friend(this.raw)
      : kind = 'friend',
        name = raw['name'] as String,
        photo = raw['photo'] as String?,
        lastMessage = raw['last_message'] as String?,
        lastFromMe = raw['last_from_me'] == true,
        at = DateTime.parse((raw['last_at'] ?? raw['since']) as String);

  final String kind;
  final Map<String, dynamic> raw;
  final String name;
  final String? photo;
  final String? lastMessage;
  final bool lastFromMe;
  final DateTime at;
}

class _TalkScreenState extends State<TalkScreen> {
  late Future<List<List<Map<String, dynamic>>>> _data = _fetch();

  static Future<List<List<Map<String, dynamic>>>> _fetch() => Future.wait([Api.myMatches(), FriendsApi.friends()]);

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_reload);
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_reload);
    super.dispose();
  }

  void _reload() => setState(() => _data = _fetch());

  Future<void> _open(_Convo c) async {
    if (c.kind == 'match') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(match: c.raw)));
    } else {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FriendChatScreen(friend: c.raw)));
    }
    _reload();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          final matches = snap.data?[0] ?? [];
          final friends = snap.data?[1] ?? [];
          final needCall = matches.where((m) => m['call_done'] != true).toList()
            ..sort((a, b) => hoursLeft(a).compareTo(hoursLeft(b)));
          final convos = <_Convo>[
            for (final m in matches) _Convo.match(m),
            for (final f in friends) _Convo.friend(f),
          ]..sort((a, b) => b.at.compareTo(a.at));
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, B.navClearance),
            children: [
              Text('Talk', style: B.display(32)),
              const SizedBox(height: 14),
              if (snap.connectionState != ConnectionState.done)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              if (needCall.isNotEmpty) ...[
                SectionLabel('Swap voice notes', color: B.urgent),
                const SizedBox(height: 10),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.05,
                  children: [for (final m in needCall) TimerTile(match: m, onTap: () => _open(_Convo.match(m)))],
                ),
                const SizedBox(height: 18),
              ],
              const SectionLabel('Conversations'),
              const SizedBox(height: 10),
              if (convos.isEmpty && snap.connectionState == ConnectionState.done)
                Container(
                  padding: const EdgeInsets.all(30),
                  decoration: B.cardBox(),
                  child: Text('No conversations yet. Like someone in Discover, or add a friend from their profile.',
                      textAlign: TextAlign.center, style: TextStyle(color: B.muted)),
                ),
              if (convos.isNotEmpty)
                Container(
                  decoration: B.cardBox(),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    for (var i = 0; i < convos.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: B.fill),
                      _Row(convo: convos[i], onTap: () => _open(convos[i])),
                    ],
                  ]),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.convo, required this.onTap});
  final _Convo convo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final match = convo.kind == 'match' ? convo.raw : null;
    final done = match?['call_done'] == true;
    final urgent = match != null && !done && hoursLeft(match) < 24;
    final theirTurn = convo.lastMessage != null && !convo.lastFromMe;
    final preview = convo.lastMessage == null
        ? (match?['icebreaker'] as String? ?? 'Say hi')
        : '${convo.lastFromMe ? 'You: ' : ''}${convo.lastMessage}';
    final (bg, fg) = urgent ? (B.urgentSoft, B.urgent) : done ? (B.okSoft, B.okInk) : (B.fill, B.ink2);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(children: [
          Avatar(path: convo.photo, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(convo.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                if (convo.kind == 'friend' && convo.raw['is_inner'] == true) ...[
                  const SizedBox(width: 5),
                  Icon(Icons.star, size: 14, color: B.goldInk),
                ],
              ]),
              Text(preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: theirTurn ? B.ink : B.muted, fontWeight: theirTurn ? FontWeight.w700 : FontWeight.w400)),
            ]),
          ),
          const SizedBox(width: 8),
          if (match != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
              child: Text(callCountdown(match), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(999)),
              child: Text('Friend', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: B.ink2)),
            ),
        ]),
      ),
    );
  }
}
