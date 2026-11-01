import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// The real-world tally (supabase/migrations/20261101000057_tally.sql): what Based got you to actually do.
/// Private unless you choose to show it on your profile.
class TallyApi {
  TallyApi._();

  /// {shown, items: [{key, label, all, month}]}; null when someone hasn't chosen to show theirs.
  static Future<Map<String, dynamic>?> get([String? userId]) async {
    final res = await Api.db.rpc('get_tally', params: {'p_user': userId});
    return res == null ? null : Map<String, dynamic>.from(res as Map);
  }

  static Future<void> setShown(bool show) => Api.db.rpc('set_show_tally', params: {'p_show': show});
}

class TallyScreen extends StatefulWidget {
  const TallyScreen({super.key});
  @override
  State<TallyScreen> createState() => _TallyScreenState();
}

class _TallyScreenState extends State<TallyScreen> {
  Map<String, dynamic>? _tally;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _tally = await TallyApi.get();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = _tally;
    final items = List<Map<String, dynamic>>.from(((t?['items'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    return Scaffold(
      appBar: AppBar(title: const Text('Real-world tally')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text('The app that gets you off the apps. This counts what you actually went and did, not likes or followers.',
                    style: TextStyle(color: B.ink2, fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                for (final i in items)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: B.cardBox(),
                    child: Row(children: [
                      Expanded(child: Text(i['label'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${i['all']}', style: B.display(26)),
                        if (((i['month'] as num?) ?? 0) > 0)
                          Text('${i['month']} this month', style: TextStyle(fontSize: 12, color: B.goldInk)),
                      ]),
                    ]),
                  ),
                const SizedBox(height: 6),
                if (t != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show it on my profile'),
                    subtitle: const Text('Off by default. Only you see it unless you turn this on.'),
                    value: t['shown'] == true,
                    onChanged: (v) async {
                      try {
                        await TallyApi.setShown(v);
                        setState(() => t['shown'] = v);
                      } catch (_) {}
                    },
                  ),
              ],
            ),
    );
  }
}

/// On someone's profile, only if they chose to show it. Only non-zero lines.
class ProfileTally extends StatelessWidget {
  const ProfileTally({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: TallyApi.get(userId == Api.me ? null : userId).catchError((_) => null),
      builder: (context, snap) {
        final t = snap.data;
        if (t == null || (userId == Api.me && t['shown'] != true)) return const SizedBox.shrink();
        final items = List<Map<String, dynamic>>.from(((t['items'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)))
            .where((i) => ((i['all'] as num?) ?? 0) > 0)
            .toList();
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SectionLabel('Out in the real world'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final i in items) Chip(label: Text('${i['label']}: ${i['all']}')),
            ]),
          ]),
        );
      },
    );
  }
}
