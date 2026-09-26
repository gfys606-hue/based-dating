import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'chat_screen.dart';

/// Talk: one inbox. Matches that still need a call sit on top as timer tiles,
/// then every conversation. (Later: sellers and groups share this same inbox.)
class TalkScreen extends StatefulWidget {
  const TalkScreen({super.key, required this.refresh, this.onChanged});
  final ValueNotifier<int> refresh;
  final VoidCallback? onChanged;
  @override
  State<TalkScreen> createState() => _TalkScreenState();
}

class _TalkScreenState extends State<TalkScreen> {
  late Future<List<Map<String, dynamic>>> _matches = Api.myMatches();

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

  void _reload() => setState(() => _matches = Api.myMatches());

  Future<void> _open(Map<String, dynamic> m) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(match: m)));
    _reload();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: FutureBuilder(
        future: _matches,
        builder: (context, snap) {
          final list = snap.data ?? [];
          final needCall = list.where((m) => m['call_done'] != true).toList()
            ..sort((a, b) => hoursLeft(a).compareTo(hoursLeft(b)));
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, B.navClearance),
            children: [
              Text('Talk', style: B.display(32)),
              const SizedBox(height: 14),
              if (snap.connectionState != ConnectionState.done)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              if (needCall.isNotEmpty) ...[
                const SectionLabel('Needs a call', color: B.urgent),
                const SizedBox(height: 10),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.05,
                  children: [for (final m in needCall) TimerTile(match: m, onTap: () => _open(m))],
                ),
                const SizedBox(height: 18),
              ],
              const SectionLabel('Conversations'),
              const SizedBox(height: 10),
              if (list.isEmpty && snap.connectionState == ConnectionState.done)
                Container(
                  padding: const EdgeInsets.all(30),
                  decoration: B.cardBox(),
                  child: const Text('No matches yet. Like someone in Discover.', textAlign: TextAlign.center, style: TextStyle(color: B.muted)),
                ),
              if (list.isNotEmpty)
                Container(
                  decoration: B.cardBox(),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(height: 1, color: Color(0xFFEFEAE2)),
                      _Row(match: list[i], onTap: () => _open(list[i])),
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
  const _Row({required this.match, required this.onTap});
  final Map<String, dynamic> match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final done = match['call_done'] == true;
    final urgent = !done && hoursLeft(match) < 24;
    final theirTurn = match['last_message'] != null && match['last_from_me'] == false;
    final preview = match['last_message'] == null
        ? (match['icebreaker'] as String? ?? 'Say hi')
        : '${match['last_from_me'] == true ? 'You: ' : ''}${match['last_message']}';
    final (bg, fg) = urgent ? (B.urgentSoft, B.urgent) : done ? (B.okSoft, const Color(0xFF1F4D32)) : (const Color(0xFFF1ECE4), B.ink2);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(children: [
          Avatar(path: match['other_photo'] as String?, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(match['other_name'] as String,
                  style: TextStyle(fontSize: 16, fontWeight: theirTurn ? FontWeight.w800 : FontWeight.w700)),
              Text(preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: theirTurn ? B.ink : B.muted, fontWeight: theirTurn ? FontWeight.w600 : FontWeight.w400)),
            ]),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
            child: Text(callCountdown(match), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
          ),
        ]),
      ),
    );
  }
}
