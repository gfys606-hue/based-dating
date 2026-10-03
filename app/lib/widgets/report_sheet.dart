import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';

/// Report someone from anywhere. Reporting also blocks them and ends any match.
/// Returns true if a report was sent.
Future<bool> showReportSheet(BuildContext context, {required String userId, required String name, String? matchId, String? where}) async {
  const cats = {
    'harassment': 'Harassment or disrespect',
    'threats': 'Threats or violence',
    'fake_profile': 'Fake profile',
    'scam': 'Scam or asking for money',
    'explicit': 'Explicit content',
    'underage': 'May be under 18',
    'spam': 'Spam or selling',
    'other': 'Something else',
  };
  String? cat;
  final details = TextEditingController();
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Report $name', style: B.heading(24)),
            const SizedBox(height: 4),
            Text('They won\'t know who reported them. Reporting also blocks them.',
                style: TextStyle(color: B.muted, fontSize: 13)),
            const SizedBox(height: 8),
            for (final c in cats.entries)
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: c.key,
                groupValue: cat,
                title: Text(c.value),
                onChanged: (v) => set(() => cat = v),
              ),
            TextField(
              controller: details,
              maxLines: 3,
              maxLength: 1000,
              decoration: const InputDecoration(hintText: 'What happened? (optional, helps us act faster)'),
            ),
            FilledButton(
              onPressed: cat == null
                  ? null
                  : () async {
                      try {
                        await Api.report(userId, cat!,
                            details: details.text.trim().isEmpty ? null : details.text.trim(), matchId: matchId, context: where);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (_) {
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Couldn\'t send it. Try again.')));
                        }
                      }
                    },
              child: const Text('SEND REPORT'),
            ),
          ]),
        ),
      ),
    ),
  );
  if (sent == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thanks. We\'ll look at it. You won\'t see them again.')));
  }
  return sent == true;
}
