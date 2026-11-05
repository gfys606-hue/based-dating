import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../brand.dart';
import '../services/conduct_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// The house rules, accepted once ("I'm in") before using the app.
class HouseRulesScreen extends StatefulWidget {
  const HouseRulesScreen({super.key, required this.rules});
  final List<Map<String, dynamic>> rules;
  @override
  State<HouseRulesScreen> createState() => _HouseRulesScreenState();
}

class _HouseRulesScreenState extends State<HouseRulesScreen> {
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await ConductApi.accept();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ConductApi.errorText(e))));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false, // you're in once you say so
        child: Scaffold(
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.fromLTRB(22, 28, 22, 28), children: [
              Text('House rules', style: B.display(34)),
              const SizedBox(height: 6),
              Text('The door is not for everyone. Here\'s what it takes to stay inside ${appName}.',
                  style: TextStyle(color: B.ink2, fontSize: 14.5, height: 1.4, fontWeight: FontWeight.w600)),
              const SizedBox(height: 22),
              for (var i = 0; i < widget.rules.length; i++) ...[
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 34,
                    child: Text('${i + 1}', style: B.display(24).copyWith(color: B.goldInk)),
                  ),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.rules[i]['title'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, height: 1.3)),
                      const SizedBox(height: 3),
                      Text(widget.rules[i]['body'] as String, style: TextStyle(color: B.muted, fontSize: 13.5, height: 1.4)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 18),
              ],
              Container(
                padding: const EdgeInsets.all(14),
                decoration: B.cardBox(),
                child: Text(
                  'Break one and there are consequences. A small slip gets a warning first. Anything serious, like '
                  'violence, goes straight to a conduct strike, which shows on your profile for a year. '
                  'You can always appeal.',
                  style: TextStyle(color: B.ink2, fontSize: 13, height: 1.45),
                ),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: _busy ? null : _accept,
                child: Text(_busy ? 'One moment…' : 'I\'M IN'),
              ),
            ]),
          ),
        ),
      );
}

/// You → Your standing: warnings and strikes, and appeals.
class StandingScreen extends StatefulWidget {
  const StandingScreen({super.key});
  @override
  State<StandingScreen> createState() => _StandingScreenState();
}

class _StandingScreenState extends State<StandingScreen> {
  List<Map<String, dynamic>>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ConductApi.mine();
      if (mounted) setState(() => _rows = r);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  Future<void> _appeal(Map<String, dynamic> s) async {
    final text = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Appeal this strike'),
        content: TextField(
          controller: text,
          maxLines: 5,
          maxLength: 1000,
          decoration: const InputDecoration(hintText: 'What happened, from your side'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('SEND')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ConductApi.appeal(s['strike_id'] as String, text.text.trim());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Appeal sent. You\'ll hear back here.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ConductApi.errorText(e))));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: Text('Your standing', style: B.heading(22))),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(18), children: [
              if (rows.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: B.cardBox(),
                  child: Text('All clear. No warnings, no strikes.', style: TextStyle(color: B.ink2, fontWeight: FontWeight.w600)),
                ),
              for (final s in rows)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: B.cardBox(border: s['active'] == true ? B.urgent : null),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SectionLabel(
                      s['level'] == 'strike' ? (s['active'] == true ? 'Conduct strike' : 'Strike, no longer showing') : 'Warning',
                      color: s['active'] == true ? B.urgent : B.muted,
                    ),
                    const SizedBox(height: 4),
                    Text(s['rule_title'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (s['note'] != null)
                      Padding(padding: const EdgeInsets.only(top: 4), child: Text(s['note'] as String, style: TextStyle(color: B.ink2))),
                    const SizedBox(height: 4),
                    Text(
                      [
                        DateFormat('MMM d, y').format(DateTime.parse(s['created_at'] as String).toLocal()),
                        if (s['active'] == true && s['expires_at'] != null)
                          'shows until ${DateFormat('MMM d, y').format(DateTime.parse(s['expires_at'] as String).toLocal())}',
                      ].join(' · '),
                      style: TextStyle(color: B.muted, fontSize: 12.5),
                    ),
                    if (s['appeal_note'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Appeal: ${s['appeal_note']}', style: TextStyle(color: B.ink2, fontSize: 13)),
                      )
                    else if (s['appealed_at'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Appeal sent. Waiting on a decision.', style: TextStyle(color: B.muted, fontSize: 13)),
                      )
                    else if (s['active'] == true)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(onPressed: () => _appeal(s), child: const Text('APPEAL')),
                      ),
                  ]),
                ),
              const SizedBox(height: 8),
              Text('A strike shows on your profile as "Conduct strike" for 12 months, then it comes off on its own. '
                  'Three at once and your account is paused while we take a look.',
                  style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4)),
            ]),
    );
  }
}
