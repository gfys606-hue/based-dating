import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../services/city_api.dart';
import '../services/invites_api.dart';
import '../services/membership_api.dart';
import '../services/push.dart';
import '../theme.dart';
import '../widgets/ui.dart';

String _clean(Object e) {
  final s = e.toString();
  final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
  return (m?.group(1) ?? s.replaceFirst(RegExp(r'^.*?(Exception|Error): ?'), '')).trim();
}

void _copy(BuildContext context, String text, [String done = 'Copied']) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
}

/// The door: shown to a new account that hasn't used an invite code yet.
class InviteGateScreen extends StatefulWidget {
  const InviteGateScreen({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  State<InviteGateScreen> createState() => _InviteGateScreenState();
}

class _InviteGateScreenState extends State<InviteGateScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _welcome;

  @override
  void initState() {
    super.initState();
    _tryCommunity();
  }

  /// A confirmed school or work email from a community Based has opened up gets straight in.
  Future<void> _tryCommunity() async {
    try {
      final name = await InvitesApi.redeemCommunity();
      if (name == null || !mounted) return;
      setState(() => _welcome = 'You\'re in through $name.');
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      widget.onDone();
    } catch (_) {}
  }

  Future<void> _redeem() async {
    if (_code.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await InvitesApi.redeem(_code.text);
      final from = r['inviter'] as String? ?? r['label'] as String?;
      setState(() => _welcome = from == null ? 'You\'re in.' : 'You\'re in. Welcome from $from.');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      widget.onDone();
    } catch (e) {
      setState(() => _error = _clean(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _waitlist() async {
    final email = TextEditingController(text: Api.db.auth.currentUser?.email ?? '');
    final name = TextEditingController();
    final note = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Join the waitlist', style: B.heading(24)),
          const SizedBox(height: 4),
          Text('We let people in a few at a time. If a member vouches for you, you\'ll get in sooner.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 12),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: 'Email')),
          const SizedBox(height: 8),
          TextField(controller: name, decoration: const InputDecoration(hintText: 'First name')),
          const SizedBox(height: 8),
          TextField(controller: note, decoration: const InputDecoration(hintText: 'Who or where did you hear about Based? (optional)')),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () async {
              try {
                await InvitesApi.joinWaitlist(email.text, name: name.text, note: note.text);
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(_clean(e))));
              }
            },
            child: const Text('PUT ME ON THE LIST'),
          ),
        ]),
      ),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You\'re on the list. We\'ll email you a code.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: B.panel,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(28), children: [
              Text('BASED', textAlign: TextAlign.center, style: B.label.copyWith(color: B.gold, fontSize: 13, letterSpacing: 6)),
              const SizedBox(height: 18),
              Text('The door is not for everyone.',
                  textAlign: TextAlign.center, style: B.sloganStyle.copyWith(fontSize: 30, color: Colors.white)),
              const SizedBox(height: 14),
              Text('Based is invite only. Enter the code you were given by a member or at a venue.',
                  textAlign: TextAlign.center, style: TextStyle(color: B.onPanelMuted, height: 1.45)),
              const SizedBox(height: 26),
              TextField(
                controller: _code,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontSize: 24, letterSpacing: 4, fontWeight: FontWeight.w700, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'XXXX-XXXX',
                  hintStyle: TextStyle(color: B.onPanelMuted.withAlpha(120), letterSpacing: 4),
                  filled: true,
                  fillColor: const Color(0x22FFFFFF),
                ),
                onSubmitted: (_) => _redeem(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: B.gold)),
                ),
              if (_welcome != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_welcome!, textAlign: TextAlign.center, style: const TextStyle(color: B.gold, fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy ? null : _redeem, child: Text(_busy ? 'Checking…' : 'ENTER')),
              const SizedBox(height: 22),
              TextButton(
                onPressed: _waitlist,
                child: Text('No code? Join the waitlist', style: TextStyle(color: B.onPanelMuted)),
              ),
              TextButton(
                onPressed: Push.signOut,
                child: Text('Sign out', style: TextStyle(color: B.onPanelMuted.withAlpha(160), fontSize: 13)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// You → Invite friends: your personal codes (3 a month for your first 6 months).
class MyInvitesScreen extends StatefulWidget {
  const MyInvitesScreen({super.key});
  @override
  State<MyInvitesScreen> createState() => _MyInvitesScreenState();
}

class _MyInvitesScreenState extends State<MyInvitesScreen> {
  Map<String, dynamic>? _d;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await InvitesApi.myInvites();
      if (mounted) setState(() => _d = d);
    } catch (_) {}
  }

  String _share(String code) => 'You\'re invited to Based. Your code: $code\nGet the app at based-social.com/test';

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final code = await InvitesApi.createInvite();
      await _load();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Your invite'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SelectableText(code, style: B.display(34).copyWith(letterSpacing: 3)),
            const SizedBox(height: 8),
            Text('Works once, for 30 days. You\'re vouching for whoever uses it.',
                textAlign: TextAlign.center, style: TextStyle(color: B.muted, fontSize: 13)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
            FilledButton(
              onPressed: () {
                _copy(ctx, _share(code), 'Invite copied. Paste it in a text.');
                Navigator.pop(ctx);
              },
              child: const Text('COPY INVITE'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final codes = List<Map<String, dynamic>>.from((d?['codes'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? const []);
    final left = d?['left'] as int? ?? 0;
    final next = d?['next_refill'] == null ? null : DateTime.parse(d!['next_refill'] as String).toLocal();
    final monthsLeft = d?['months_left'] as int? ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text('Invite friends', style: B.heading(22))),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(18), children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(B.radius)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$left', style: B.display(48).copyWith(color: B.gold)),
                  Text(left == 1 ? 'invite left this month' : 'invites left this month',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    d['frozen'] == true
                        ? 'Your invites are paused for now.'
                        : monthsLeft > 0 && next != null
                            ? 'Back to 3 on ${DateFormat('MMM d').format(next)} · $monthsLeft more ${monthsLeft == 1 ? 'month' : 'months'} of invites. Unused ones don\'t carry over.'
                            : 'That\'s your last month of invites.',
                    style: TextStyle(color: B.onPanelMuted, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _busy || left <= 0 || d['frozen'] == true ? null : _create,
                    icon: const Icon(Icons.vpn_key_outlined),
                    label: const Text('CREATE AN INVITE'),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Text('Only invite people you\'d vouch for. If someone you invite gets banned, your invites are paused.',
                  style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4)),
              const SizedBox(height: 18),
              if (codes.isNotEmpty) const SectionLabel('Your codes'),
              for (final c in codes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c['code'] as String, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 2)),
                  subtitle: Text(c['used'] == true
                      ? 'Used by ${c['joined'] ?? 'someone'}'
                      : c['active'] != true
                          ? 'Turned off'
                          : 'Not used yet · expires ${DateFormat('MMM d').format(DateTime.parse(c['expires_at'] as String).toLocal())}'),
                  trailing: c['used'] == true || c['active'] != true
                      ? null
                      : IconButton(
                          tooltip: 'Copy invite',
                          icon: const Icon(Icons.copy),
                          onPressed: () => _copy(context, _share(c['code'] as String), 'Invite copied'),
                        ),
                ),
            ]),
    );
  }
}

/// Admin only: the door switch, venue code batches, sign-ups by venue, and the waitlist.
class AdminDoorScreen extends StatefulWidget {
  const AdminDoorScreen({super.key});
  @override
  State<AdminDoorScreen> createState() => _AdminDoorScreenState();
}

class _AdminDoorScreenState extends State<AdminDoorScreen> {
  List<Map<String, dynamic>> _stats = [];
  List<Map<String, dynamic>> _wait = [];
  bool? _inviteOnly;
  bool? _fullAccess;
  bool? _activityLight;
  bool? _paidOpen;
  List<Map<String, dynamic>> _communities = [];
  List<Map<String, dynamic>> _cities = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    CityApi.all().then((c) {
      if (mounted) setState(() => _cities = c);
    }).catchError((_) {});
    MembershipApi.mine().then((m) {
      if (mounted) setState(() => _paidOpen = m['open'] == true);
    }).catchError((_) {});
    try {
      final r = await Future.wait([InvitesApi.stats(), InvitesApi.waitlist(), InvitesApi.access(), InvitesApi.communities()]);
      if (mounted) {
        setState(() {
          _stats = r[0] as List<Map<String, dynamic>>;
          _wait = r[1] as List<Map<String, dynamic>>;
          _inviteOnly = (r[2] as Map<String, dynamic>)['invite_only'] == true;
          _fullAccess = (r[2] as Map<String, dynamic>)['full_access_for_new'] != false;
          _activityLight = (r[2] as Map<String, dynamic>)['show_activity_light'] == true;
          _communities = r[3] as List<Map<String, dynamic>>;
        });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
  }

  Future<void> _newBatch() async {
    final codes = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _NewBatchSheet(),
    );
    if (codes == null || !mounted) return;
    await _load();
    if (!mounted) return;
    _showCodes('New codes', codes);
  }

  void _showCodes(String title, List<String> codes) => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: SelectableText(codes.join('\n'), style: const TextStyle(fontSize: 18, letterSpacing: 2, height: 1.6)),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            FilledButton(onPressed: () => _copy(ctx, codes.join('\n'), '${codes.length} codes copied'), child: const Text('COPY ALL')),
          ],
        ),
      );

  Future<void> _openLabel(String label) async {
    final rows = await InvitesApi.codes(label).catchError((_) => <Map<String, dynamic>>[]);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .75),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(18), children: [
              Row(children: [
                Expanded(child: Text(label, style: B.heading(22))),
                TextButton(
                  onPressed: () => _copy(ctx, rows.where((r) => r['active'] == true && (r['uses'] as int) < (r['max_uses'] as int)).map((r) => r['code']).join('\n'), 'Unused codes copied'),
                  child: const Text('COPY UNUSED'),
                ),
              ]),
              for (final r in rows)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(r['code'] as String, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 2)),
                  subtitle: Text('${r['uses']} of ${r['max_uses']} used'
                      '${r['expires_at'] == null ? '' : ' · expires ${DateFormat('MMM d').format(DateTime.parse(r['expires_at'] as String).toLocal())}'}'),
                  value: r['active'] == true,
                  onChanged: (v) async {
                    await InvitesApi.setCodeActive(r['code'] as String, v).catchError((_) {});
                    set(() => r['active'] = v);
                  },
                ),
            ]),
          ),
        ),
      ),
    );
    _load();
  }

  Future<void> _addCity() async {
    final name = TextEditingController();
    final region = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a city'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'City', hintText: 'Edmonton')),
          TextField(controller: region, decoration: const InputDecoration(labelText: 'Province or state', hintText: 'Alberta')),
          const SizedBox(height: 8),
          const Text('It starts closed. Switch it on when you\'re ready to open it.', style: TextStyle(fontSize: 12.5)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ADD')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      await CityApi.add(name.text.trim(), region: region.text.trim().isEmpty ? null : region.text.trim());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    _load();
  }

  Future<void> _addCommunity() async {
    final name = TextEditingController();
    final domains = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a community'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'University of Calgary')),
          TextField(controller: domains, decoration: const InputDecoration(labelText: 'Email domains', hintText: 'ucalgary.ca, mru.ca')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ADD')),
        ],
      ),
    );
    if (ok != true) return;
    final list = domains.text.split(RegExp(r'[,\s]+')).where((d) => d.trim().isNotEmpty).toList();
    try {
      await InvitesApi.addCommunity(name.text.trim(), list);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    _load();
  }

  Future<void> _admit(Map<String, dynamic> w) async {
    try {
      final code = await InvitesApi.admit(w['id'] as int);
      await _load();
      final email = w['email'] as String;
      final body = Uri.encodeComponent('You\'re in. Your Based code: $code\n\nGet the app at based-social.com/test and enter it when you sign up.');
      await launchUrl(Uri.parse('mailto:$email?subject=${Uri.encodeComponent('Your invite to Based')}&body=$body'));
      if (mounted) _copy(context, code, 'Code $code copied (and an email draft opened)');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _wait.where((w) => w['status'] == 'waiting').toList();
    return Scaffold(
      appBar: AppBar(title: Text('The door', style: B.heading(22))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(18), children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _inviteOnly ?? true,
            title: const Text('Invite only'),
            subtitle: Text(_inviteOnly == false ? 'Anyone can sign up right now.' : 'New sign-ups need a code or wait on the list.'),
            onChanged: _inviteOnly == null
                ? null
                : (v) async {
                    await InvitesApi.setInviteOnly(v).catchError((_) {});
                    _load();
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _fullAccess ?? true,
            title: const Text('Full access for new members'),
            subtitle: Text(_fullAccess == false
                ? 'New members get Ouch (dating) only. Herd, Events and plans stay for testers.'
                : 'Anyone who joins with a code gets Herd, Events and plans too.'),
            onChanged: _fullAccess == null
                ? null
                : (v) async {
                    await InvitesApi.setFullAccess(v).catchError((_) {});
                    _load();
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _activityLight ?? false,
            title: const Text('Show members their activity light'),
            subtitle: Text(_activityLight == true
                ? 'Members see green / yellow / red on their You page, with a tip.'
                : 'Hidden. Activity still shapes who gets seen, quietly.'),
            onChanged: _activityLight == null
                ? null
                : (v) async {
                    await InvitesApi.setActivityLight(v).catchError((_) {});
                    _load();
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _paidOpen ?? false,
            title: const Text('Paid memberships'),
            subtitle: Text(_paidOpen == true
                ? 'Plus and Inner can be bought. Picks, undo and travel mode need a plan.'
                : 'Free for everyone: 50 picks, undo and travel mode. Nothing can be charged.'),
            onChanged: _paidOpen == null
                ? null
                : (v) async {
                    final ok = !v ||
                        await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Start charging?'),
                                content: const Text('Members lose the free perks unless they buy Plus or Inner. '
                                    'Make sure the Stripe keys and prices are set first.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('TURN ON')),
                                ],
                              ),
                            ) ==
                            true;
                    if (!ok) return;
                    await MembershipApi.setOpen(v).catchError((_) {});
                    _load();
                  },
          ),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: _newBatch, icon: const Icon(Icons.add), label: const Text('NEW VENUE CODES')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => const _CompSheet()),
            icon: const Icon(Icons.workspace_premium_outlined),
            label: const Text('MEMBERSHIPS AND COMPS'),
          ),
          const SizedBox(height: 22),
          Row(children: [
            const Expanded(child: SectionLabel('Communities')),
            TextButton.icon(onPressed: _addCommunity, icon: const Icon(Icons.add, size: 18), label: const Text('ADD')),
          ]),
          Text('Anyone with a confirmed email from these domains gets straight in.', style: TextStyle(color: B.muted, fontSize: 12.5)),
          if (_communities.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('None yet.', style: TextStyle(color: B.muted))),
          for (final c in _communities)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${(c['domains'] as List).join(', ')} · ${c['joined']} joined'),
              value: c['active'] == true,
              onChanged: (v) async {
                await InvitesApi.setCommunityActive(c['id'] as String, v).catchError((_) {});
                _load();
              },
            ),
          const SizedBox(height: 22),
          Row(children: [
            const Expanded(child: SectionLabel('Cities')),
            TextButton.icon(onPressed: _addCity, icon: const Icon(Icons.add, size: 18), label: const Text('ADD')),
          ]),
          Text('Open cities show in everyone\'s city pull-down. Ouch only matches people in the same city.',
              style: TextStyle(color: B.muted, fontSize: 12.5)),
          for (final c in _cities)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text([c['name'], c['region']].whereType<String>().join(', '), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${c['members']} members · ${c['active'] == true ? 'open' : 'not open yet'}'),
              value: c['active'] == true,
              onChanged: (v) async {
                try {
                  await CityApi.setOpen(c['slug'] as String, v);
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
                }
                _load();
              },
            ),
          const SizedBox(height: 22),
          const SectionLabel('Sign-ups by source'),
          const SizedBox(height: 8),
          if (_stats.isEmpty) Text('No codes yet.', style: TextStyle(color: B.muted)),
          for (final s in _stats)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s['label'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${s['joined']} joined · ${s['active_members']} active · '
                  '${s['used']}/${s['capacity']} uses · ${s['codes']} ${s['codes'] == 1 ? 'code' : 'codes'}'),
              trailing: s['kind'] == 'personal' ? null : const Icon(Icons.chevron_right),
              onTap: s['kind'] == 'personal' ? null : () => _openLabel(s['label'] as String),
            ),
          const SizedBox(height: 18),
          SectionLabel('Waitlist · ${waiting.length} waiting'),
          const SizedBox(height: 8),
          for (final w in _wait)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text([w['name'], w['email']].whereType<String>().where((x) => x.isNotEmpty).join(' · ')),
              subtitle: Text([
                if ((w['note'] as String?)?.isNotEmpty == true) w['note'] as String,
                'since ${DateFormat('MMM d').format(DateTime.parse(w['created_at'] as String).toLocal())}',
                if (w['invite_code'] != null) 'code ${w['invite_code']}',
              ].join(' · ')),
              trailing: w['status'] == 'waiting'
                  ? FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 12)),
                      onPressed: () => _admit(w),
                      child: const Text('LET IN'),
                    )
                  : Icon(Icons.check, color: B.goldInk),
            ),
        ]),
      ),
    );
  }
}

class _NewBatchSheet extends StatefulWidget {
  const _NewBatchSheet();
  @override
  State<_NewBatchSheet> createState() => _NewBatchSheetState();
}

class _NewBatchSheetState extends State<_NewBatchSheet> {
  final _label = TextEditingController();
  String _kind = 'single';
  int _count = 20;
  int _uses = 50;
  int? _days = 30;
  bool _busy = false;
  String? _error;

  Future<void> _make() async {
    if (_label.text.trim().isEmpty) {
      setState(() => _error = 'Give it a label, like the venue name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final codes = await InvitesApi.createCodes(kind: _kind, label: _label.text.trim(), count: _count, maxUses: _uses, days: _days);
      if (mounted) Navigator.pop(context, codes);
    } catch (e) {
      if (mounted) setState(() => _error = _clean(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('New venue codes', style: B.heading(24)),
        const SizedBox(height: 12),
        TextField(controller: _label, decoration: const InputDecoration(hintText: 'Label, e.g. Heavily Redacted')),
        const SizedBox(height: 12),
        Wrap(spacing: 6, children: [
          ChoiceChip(label: const Text('Bartender passes (1 use each)'), selected: _kind == 'single', onSelected: (_) => setState(() => _kind = 'single')),
          ChoiceChip(label: const Text('Menu code (many uses)'), selected: _kind == 'limited', onSelected: (_) => setState(() => _kind = 'limited')),
        ]),
        const SizedBox(height: 12),
        if (_kind == 'single') ...[
          const SectionLabel('How many passes'),
          Wrap(spacing: 6, children: [
            for (final n in const [10, 20, 50, 100]) ChoiceChip(label: Text('$n'), selected: _count == n, onSelected: (_) => setState(() => _count = n)),
          ]),
        ] else ...[
          const SectionLabel('How many people can use it'),
          Wrap(spacing: 6, children: [
            for (final n in const [25, 50, 100, 250]) ChoiceChip(label: Text('$n'), selected: _uses == n, onSelected: (_) => setState(() => _uses = n)),
          ]),
        ],
        const SizedBox(height: 12),
        const SectionLabel('Expires'),
        Wrap(spacing: 6, children: [
          for (final d in const [7, 30, 90, null])
            ChoiceChip(label: Text(d == null ? 'Never' : '$d days'), selected: _days == d, onSelected: (_) => setState(() => _days = d)),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: B.urgent))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _make, child: Text(_busy ? 'Making…' : 'MAKE CODES')),
      ]),
    );
  }
}

/// The door → Memberships and comps: see who's paying, and give someone Plus or Inner for free.
class _CompSheet extends StatefulWidget {
  const _CompSheet();
  @override
  State<_CompSheet> createState() => _CompSheetState();
}

class _CompSheetState extends State<_CompSheet> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    try {
      final r = await MembershipApi.members(query: _q.text);
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _grant(Map<String, dynamic> r) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(r['name'] as String? ?? 'Member', style: B.heading(20))),
          for (final o in const [
            ['plus:30', 'Plus for 30 days'],
            ['plus:365', 'Plus for a year'],
            ['inner:30', 'Inner for 30 days'],
            ['inner:365', 'Inner for a year'],
            ['free:0', 'Remove comp'],
          ])
            ListTile(title: Text(o[1]), onTap: () => Navigator.pop(ctx, o[0])),
        ]),
      ),
    );
    if (pick == null) return;
    final parts = pick.split(':');
    try {
      await MembershipApi.grant(r['user_id'] as String, parts[0], days: int.parse(parts[1]));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    _search();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .8),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(18), children: [
              Text('Memberships', style: B.heading(22)),
              const SizedBox(height: 4),
              Text('Paying and comped members. Search anyone by name or email to comp them.',
                  style: TextStyle(color: B.muted, fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                controller: _q,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name or email'),
              ),
              if (_loading) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
              if (!_loading && _rows.isEmpty)
                Padding(padding: const EdgeInsets.all(16), child: Text('No one yet.', style: TextStyle(color: B.muted))),
              for (final r in _rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(r['name'] as String? ?? '(no profile)'),
                  subtitle: Text([
                    r['email'] ?? '',
                    switch (r['tier']) { 'inner' => 'Inner', 'plus' => 'Plus', _ => 'Free' },
                    if (r['source'] == 'admin') 'comped',
                    if (r['until'] != null) 'until ${DateFormat('MMM d, y').format(DateTime.parse(r['until'] as String).toLocal())}',
                  ].where((s) => '$s'.isNotEmpty).join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _grant(r),
                ),
            ]),
          ),
        ),
      );
}
