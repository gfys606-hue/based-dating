import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/invites_api.dart';
import '../theme.dart';

String _clean(Object e) {
  final s = e.toString();
  final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
  return (m?.group(1) ?? s.replaceFirst(RegExp(r'^.*?(Exception|Error): ?'), '')).trim();
}

/// The public waitlist: no account needed. Email, city (open ones in the picker, or type yours),
/// an optional reference code from a member, and 18+. The confirmation never shows a place in line.
Future<void> showWaitlistSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _WaitlistSheet(),
    );

class _WaitlistSheet extends StatefulWidget {
  const _WaitlistSheet();
  @override
  State<_WaitlistSheet> createState() => _WaitlistSheetState();
}

class _WaitlistSheetState extends State<_WaitlistSheet> {
  static const _elsewhere = '__elsewhere';
  final _email = TextEditingController();
  final _other = TextEditingController();
  final _ref = TextEditingController();
  List<Map<String, dynamic>> _cities = [];
  String? _city;
  bool _adult = false;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _done;

  @override
  void initState() {
    super.initState();
    InvitesApi.waitlistCities().then((c) {
      if (mounted) setState(() {
        _cities = c;
        if (c.isNotEmpty) _city = c.first['slug'] as String;
      });
    }).catchError((_) {});
  }

  Map<String, dynamic>? get _picked => _cities.where((c) => c['slug'] == _city).firstOrNull;

  Future<void> _join() async {
    final city = _city == _elsewhere ? _other.text.trim() : (_picked?['name'] as String? ?? _other.text.trim());
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await InvitesApi.joinWaitlistSite(
        email: _email.text.trim(),
        city: city,
        ref: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
        adult: _adult,
      );
      if (mounted) setState(() => _done = {...r, 'city': city});
    } catch (e) {
      if (mounted) setState(() => _error = _clean(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final n = NumberFormat.decimalPattern();
    final done = _done;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: done != null
            ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('You\'re on the list.', style: B.heading(26)),
                const SizedBox(height: 8),
                Text(
                  done['city_open'] == true
                      ? 'We let people into ${done['city']} as spots open. We\'ll email you when yours does.'
                      : 'Based isn\'t open in ${done['city']} yet. When it opens there, everyone on the list hears first.',
                  style: TextStyle(color: B.ink2, height: 1.45),
                ),
                if (done['ref_valid'] == true) ...[
                  const SizedBox(height: 8),
                  Text('Your reference code checks out.', style: TextStyle(color: B.goldInk, fontWeight: FontWeight.w700)),
                ],
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('DONE')),
              ])
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Join the waitlist', style: B.heading(26)),
                const SizedBox(height: 4),
                Text('Every city has a member cap. Spots open in drops; members\' references go first.',
                    style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
                const SizedBox(height: 14),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(hintText: 'Email'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _city,
                  isExpanded: true,
                  decoration: const InputDecoration(hintText: 'Your city'),
                  items: [
                    for (final c in _cities)
                      DropdownMenuItem(value: c['slug'] as String, child: Text([c['name'], c['region']].whereType<String>().join(', '))),
                    const DropdownMenuItem(value: _elsewhere, child: Text('Somewhere else')),
                  ],
                  onChanged: (v) => setState(() => _city = v),
                ),
                if (_picked?['cap'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('${_picked!['name']}: ${n.format(_picked!['members'])} of ${n.format(_picked!['cap'])} members',
                        style: TextStyle(color: B.muted, fontSize: 12.5)),
                  ),
                if (_city == _elsewhere || _cities.isEmpty) ...[
                  const SizedBox(height: 10),
                  TextField(controller: _other, decoration: const InputDecoration(hintText: 'Which city?')),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: _ref,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(hintText: 'Reference code from a member (optional)'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _adult,
                  onChanged: (v) => setState(() => _adult = v == true),
                  title: const Text('I\'m 18 or older'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: TextStyle(color: B.urgent))),
                FilledButton(onPressed: _busy ? null : _join, child: Text(_busy ? 'Saving…' : 'PUT ME ON THE LIST')),
              ]),
      ),
    );
  }
}
