import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/membership_api.dart';
import '../theme.dart';
import '../widgets/friend_button.dart';
import '../widgets/report_sheet.dart';
import '../widgets/self_expression.dart';
import '../widgets/signed_photo.dart';

/// A profile = photos + interests (shared ones highlighted) + recent activity. No bio.
class ProfileViewScreen extends StatelessWidget {
  const ProfileViewScreen({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(actions: [
        if (userId != Api.me)
          PopupMenuButton<String>(
            onSelected: (v) async {
              final p = await Api.profile(userId);
              final name = p?['name'] as String? ?? 'this person';
              if (!context.mounted) return;
              if (v == 'report') {
                if (await showReportSheet(context, userId: userId, name: name, where: 'profile') && context.mounted) {
                  Navigator.of(context).pop();
                }
              } else if (v == 'block') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Block $name?'),
                    content: const Text('You won\'t see each other anywhere on Based. They aren\'t told.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('BLOCK')),
                    ],
                  ),
                );
                if (ok == true) {
                  await Api.block(userId);
                  if (context.mounted) Navigator.of(context).pop();
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'report', child: Text('Report')),
              PopupMenuItem(value: 'block', child: Text('Block')),
            ],
          ),
      ]),
      body: FutureBuilder(
        future: Api.profile(userId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          final p = snap.data;
          if (p == null) return const Center(child: Text('Profile unavailable'));
          return ProfileBody(profile: p);
        },
      ),
    );
  }
}

class ProfileBody extends StatelessWidget {
  const ProfileBody({super.key, required this.profile});
  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final photos = List<String>.from(profile['photos'] ?? const []);
    final interests = List<Map<String, dynamic>>.from(profile['interests'] ?? const []);
    final activity = List<Map<String, dynamic>>.from(profile['recent_activity'] ?? const []);
    final scheme = Theme.of(context).colorScheme;
    final lately = List<Map<String, dynamic>>.from(profile['lately'] ?? const []);
    final voice = profile['voice'] == null ? null : Map<String, dynamic>.from(profile['voice'] as Map);
    final stance = profile['stance'] == null ? null : Map<String, dynamic>.from(profile['stance'] as Map);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          height: 460,
          child: PageView(children: [
            for (final ph in photos) Padding(padding: const EdgeInsets.only(right: 4), child: SignedPhoto(ph, radius: 4)),
          ]),
        ),
        const SizedBox(height: 12),
        Text('${profile['name']}, ${profile['age']}', style: B.display(34)),
        if (profile['dating_on'] == true && profile['is_me'] != true)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Icon(Icons.favorite, size: 14, color: B.goldInk),
              const SizedBox(width: 6),
              Text('OUCH', style: B.label.copyWith(color: B.accentStrong)),
            ]),
          ),
        if (profile['is_me'] != true)
          FutureBuilder(
            // Only shows when you're both Inner
            future: MembershipApi.innerMark(profile['id'] as String).catchError((_) => false),
            builder: (context, snap) => snap.data == true
                ? Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Icon(Icons.workspace_premium, size: 14, color: B.goldInk),
                      const SizedBox(width: 6),
                      Text('INNER', style: B.label.copyWith(color: B.goldInk)),
                    ]),
                  )
                : const SizedBox.shrink(),
          ),
        if (profile['venue_mark'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Icon(Icons.do_not_disturb_on_outlined, size: 14, color: B.urgent),
              const SizedBox(width: 6),
              Text('BARRED BY 3 VENUES THIS YEAR', style: B.label.copyWith(color: B.urgent)),
            ]),
          ),
        if (profile['joined_via'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Icon(Icons.vpn_key, size: 14, color: B.goldInk),
              const SizedBox(width: 6),
              Text('JOINED THROUGH ${(profile['joined_via'] as String).toUpperCase()}', style: B.label.copyWith(color: B.accentStrong)),
            ]),
          ),
        if (profile['is_me'] != true) ...[
          const SizedBox(height: 12),
          FriendButton(userId: profile['id'] as String, name: profile['name'] as String),
        ],
        if (lately.isNotEmpty) ...[
          const SizedBox(height: 14),
          LatelyStrip(items: lately),
        ],
        if (voice != null) ...[
          const SizedBox(height: 16),
          VoiceNoteCard(voice: voice),
        ],
        if (stance != null) ...[
          const SizedBox(height: 12),
          StanceCard(userId: profile['id'] as String, stance: stance, isMe: profile['is_me'] == true),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final i in interests)
            Chip(
              label: Text(i['name'] as String),
              backgroundColor: i['shared'] == true ? scheme.primaryContainer : null,
              avatar: i['shared'] == true ? const Icon(Icons.check, size: 16) : null,
            ),
        ]),
        const SizedBox(height: 20),
        Text('Recent activity', style: Theme.of(context).textTheme.titleMedium),
        if (activity.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Nothing posted yet.')),
        for (final a in activity)
          Card(
            child: ListTile(
              title: Text(a['body'] as String? ?? ''),
              subtitle: Text(a['topic'] as String),
            ),
          ),
      ],
    );
  }
}
