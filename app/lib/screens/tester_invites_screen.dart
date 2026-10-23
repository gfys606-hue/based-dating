import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../brand.dart';
import '../services/invites_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Owner only (You → Invite testers): single-use codes that give the person who signs up with them
/// all modules, plus Premium for a set time if chosen.
/// (supabase/migrations/20261023000045_tester_codes.sql)
class TesterInvitesScreen extends StatefulWidget {
  const TesterInvitesScreen({super.key});
  @override
  State<TesterInvitesScreen> createState() => _TesterInvitesScreenState();
}

class _TesterInvitesScreenState extends State<TesterInvitesScreen> {
  int _count = 1;
  int _premiumDays = 90; // 0 = no Premium
  bool _busy = false;
  List<Map<String, dynamic>>? _codes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await InvitesApi.testerCodes();
      if (mounted) setState(() => _codes = r);
    } catch (e) {
      if (mounted) setState(() => _codes = []);
      _say(_clean(e));
    }
  }

  String _clean(Object e) {
    final s = e.toString();
    final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
    return (m?.group(1) ?? s.replaceFirst(RegExp(r'^.*?(Exception|Error): ?'), '')).trim();
  }

  void _say(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  String _message(String code) =>
      'You\'re in as a ${appName} tester. Get the app at based-social.com/test, sign up, and enter this code: $code\n'
      'It works once, for 30 days.';

  void _copy(String text, String done) {
    Clipboard.setData(ClipboardData(text: text));
    _say(done);
  }

  Future<void> _make() async {
    setState(() => _busy = true);
    try {
      final codes = await InvitesApi.createTesterCodes(count: _count, premiumDays: _premiumDays);
      await _load();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(codes.length == 1 ? 'Tester code' : '${codes.length} tester codes'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: SelectableText(codes.join('\n'), style: const TextStyle(fontSize: 20, letterSpacing: 2, height: 1.6)),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            if (codes.length == 1)
              FilledButton(
                onPressed: () => _copy(_message(codes.first), 'Invite message copied'),
                child: const Text('COPY MESSAGE'),
              )
            else
              FilledButton(onPressed: () => _copy(codes.join('\n'), '${codes.length} codes copied'), child: const Text('COPY ALL')),
          ],
        ),
      );
    } catch (e) {
      _say(_clean(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d');
    final codes = _codes;
    return Scaffold(
      appBar: AppBar(title: Text('Invite testers', style: B.heading(22))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(18), children: [
          Text('Each code works once, for 30 days. Whoever signs up with it gets every module '
              '(Herd, Events, plans)${_premiumDays > 0 ? ' and Premium for $_premiumDays days' : ''}.',
              style: TextStyle(color: B.muted, height: 1.4)),
          const SizedBox(height: 16),
          const SectionLabel('How many codes'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            for (final n in const [1, 5, 10, 25])
              ChoiceChip(label: Text('$n'), selected: _count == n, onSelected: (_) => setState(() => _count = n)),
          ]),
          const SizedBox(height: 14),
          const SectionLabel('Premium included'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            for (final o in const [[0, 'None'], [30, '30 days'], [90, '90 days'], [365, '1 year']])
              ChoiceChip(
                label: Text(o[1] as String),
                selected: _premiumDays == o[0],
                onSelected: (_) => setState(() => _premiumDays = o[0] as int),
              ),
          ]),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _busy ? null : _make,
            icon: const Icon(Icons.vpn_key_outlined),
            label: Text(_count == 1 ? 'MAKE A TESTER CODE' : 'MAKE $_count TESTER CODES'),
          ),
          const SizedBox(height: 26),
          const SectionLabel('Tester codes'),
          const SizedBox(height: 4),
          if (codes == null)
            const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
          else if (codes.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text('None yet.', style: TextStyle(color: B.muted)))
          else
            for (final c in codes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c['code'] as String, style: const TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                subtitle: Text([
                  if (c['used'] == true) 'Used${c['used_by'] != null ? ' by ${c['used_by']}' : ''}'
                  else if (c['expires_at'] != null && DateTime.parse(c['expires_at'] as String).isBefore(DateTime.now())) 'Expired'
                  else if (c['expires_at'] != null) 'Open until ${fmt.format(DateTime.parse(c['expires_at'] as String).toLocal())}',
                  c['premium_days'] == null ? 'no Premium' : 'Premium ${c['premium_days']} days',
                ].join(' · ')),
                trailing: c['used'] == true
                    ? Icon(Icons.check, color: B.goldInk)
                    : IconButton(
                        tooltip: 'Copy invite message',
                        icon: const Icon(Icons.copy),
                        onPressed: () => _copy(_message(c['code'] as String), 'Invite message copied'),
                      ),
              ),
        ]),
      ),
    );
  }
}
