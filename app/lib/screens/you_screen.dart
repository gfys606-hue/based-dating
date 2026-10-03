import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/push.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'edit_profile_screen.dart';
import 'invite_screens.dart';
import 'profile_view_screen.dart';

/// You: your profile and account.
class YouScreen extends StatelessWidget {
  const YouScreen({super.key, required this.onStatusChanged});
  final VoidCallback onStatusChanged;

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, String label, VoidCallback onTap, {Color? color}) => ListTile(
          leading: Icon(icon, color: color ?? B.ink2),
          title: Text(label, style: TextStyle(color: color ?? B.ink, fontSize: 16)),
          onTap: onTap,
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, B.navClearance),
      children: [
        Text('You', style: B.display(32)),
        const SizedBox(height: 16),
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: Api.me))),
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: B.cardBox(),
            child: Row(children: [
              CircleAvatar(radius: 30, backgroundColor: B.avatarFill, child: Icon(Icons.person, color: B.ink2, size: 30)),
              SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Your profile', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                  Text('See it the way others do', style: TextStyle(color: B.muted, fontSize: 13)),
                ]),
              ),
              Icon(Icons.chevron_right, color: B.muted),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: B.cardBox(),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: B.card,
            child: Column(children: [
              row(Icons.edit_outlined, 'Edit profile', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditProfileScreen()))),
              Divider(height: 1, color: B.fill),
              row(Icons.vpn_key_outlined, 'Invite friends', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyInvitesScreen()))),
              FutureBuilder(
                future: Api.myProfile(),
                builder: (context, snap) => snap.data?['is_admin'] == true
                    ? Column(children: [
                        Divider(height: 1, color: B.fill),
                        row(Icons.door_front_door_outlined, 'The door (admin)',
                            () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminDoorScreen()))),
                      ])
                    : const SizedBox.shrink(),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        const SectionLabel('Appearance'),
        const SizedBox(height: 10),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: B.mode,
          builder: (context, mode, _) => Segmented(
            options: const ['Phone setting', 'Light', 'Dark'],
            index: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark].indexOf(mode),
            onChanged: (i) => B.setMode(const [ThemeMode.system, ThemeMode.light, ThemeMode.dark][i]),
          ),
        ),
        const SizedBox(height: 20),
        const SectionLabel('Account'),
        const SizedBox(height: 10),
        Container(
          decoration: B.cardBox(),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: B.card,
            child: Column(children: [
              row(Icons.refresh, 'Refresh account status', onStatusChanged),
              Divider(height: 1, color: B.fill),
              row(Icons.logout, 'Sign out', Push.signOut, color: B.urgent),
              Divider(height: 1, color: B.fill),
              row(Icons.delete_forever_outlined, 'Delete account', () => _confirmDelete(context), color: B.urgent),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Your engagement score is never shown, to you or anyone. No premium tier: everything that helps you meet people is free.',
          style: TextStyle(color: B.muted, fontSize: 13, height: 1.5),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
            'This permanently deletes your profile, photos, matches and messages. It can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: B.urgent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.deleteAccount();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete your account. Please try again.')),
        );
      }
    }
  }
}
