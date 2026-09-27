import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
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
          borderRadius: BorderRadius.circular(22),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: Api.me))),
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: B.cardBox(),
            child: const Row(children: [
              CircleAvatar(radius: 30, backgroundColor: Color(0xFFD9CDBD), child: Icon(Icons.person, color: B.ink2, size: 30)),
              SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Your profile', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  Text('See it the way others do', style: TextStyle(color: B.muted, fontSize: 13)),
                ]),
              ),
              Icon(Icons.chevron_right, color: B.muted),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        const SectionLabel('Account'),
        const SizedBox(height: 10),
        Container(
          decoration: B.cardBox(),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.white,
            child: Column(children: [
              row(Icons.refresh, 'Refresh account status', onStatusChanged),
              const Divider(height: 1, color: Color(0xFFEFEAE2)),
              row(Icons.logout, 'Sign out', () => Api.db.auth.signOut(), color: B.urgent),
              const Divider(height: 1, color: Color(0xFFEFEAE2)),
              row(Icons.delete_forever_outlined, 'Delete account', () => _confirmDelete(context), color: B.urgent),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
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
            child: const Text('Delete', style: TextStyle(color: B.urgent, fontWeight: FontWeight.w700)),
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
