import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/friend_button.dart';
import '../widgets/self_expression.dart';
import '../widgets/signed_photo.dart';

/// A profile = photos + interests (shared ones highlighted) + recent activity. No bio.
class ProfileViewScreen extends StatelessWidget {
  const ProfileViewScreen({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
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
        if (profile['joined_via'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              const Icon(Icons.vpn_key, size: 14, color: B.gold),
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
