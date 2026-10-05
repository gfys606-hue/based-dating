import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/membership_api.dart';
import '../services/venue_api.dart';
import '../theme.dart';
import '../widgets/place_widgets.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

String _err(Object e) {
  final s = e.toString();
  final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
  return (m?.group(1) ?? 'Something went wrong. Try again.').trim();
}

String _when(String iso) => DateFormat('EEE MMM d · h:mm a').format(DateTime.parse(iso).toLocal());

/// You → I run a venue: ask to be confirmed as owner or manager.
class VenueApplyScreen extends StatefulWidget {
  const VenueApplyScreen({super.key});
  @override
  State<VenueApplyScreen> createState() => _VenueApplyScreenState();
}

class _VenueApplyScreenState extends State<VenueApplyScreen> {
  Map<String, dynamic>? _place;
  String _role = 'owner';
  final _note = TextEditingController();
  bool _busy = false;

  Future<void> _send() async {
    if (_place == null) return;
    setState(() => _busy = true);
    try {
      await VenueApi.apply(_place!['place_id'] as String, _role, note: _note.text.trim().isEmpty ? null : _note.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent. We\'ll confirm you and let you know.')));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('I run a venue', style: B.heading(22))),
        body: ListView(padding: const EdgeInsets.all(18), children: [
          Text('Your room, your crowd, your call on who belongs.', style: B.sloganStyle.copyWith(fontSize: 22)),
          const SizedBox(height: 10),
          Text('Once we confirm you, you can see table requests from groups heading your way, '
              'and ask us to bar someone who caused trouble.',
              style: TextStyle(color: B.muted, height: 1.45)),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () async {
              final p = await pickPlace(context, title: 'Which venue?');
              if (p != null) setState(() => _place = p);
            },
            icon: const Icon(Icons.place_outlined),
            label: Text(_place == null ? 'Pick your venue' : _place!['name'] as String),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 6, children: [
            ChoiceChip(label: const Text('Owner'), selected: _role == 'owner', onSelected: (_) => setState(() => _role = 'owner')),
            ChoiceChip(label: const Text('Manager'), selected: _role == 'manager', onSelected: (_) => setState(() => _role = 'manager')),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'How can we confirm it\'s you? (e.g. your role, a work email or phone)'),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy || _place == null ? null : _send, child: const Text('SEND')),
        ]),
      );
}

/// Staff dashboard for one venue: table requests, people who've been in, and bars.
class MyVenueScreen extends StatelessWidget {
  const MyVenueScreen({super.key, required this.venue});
  final Map<String, dynamic> venue;
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: Text(venue['name'] as String, style: B.heading(22)),
            bottom: const TabBar(tabs: [Tab(text: 'Tables'), Tab(text: 'Passes'), Tab(text: 'People'), Tab(text: 'Bars')]),
          ),
          body: TabBarView(children: [
            _TablesTab(venue: venue),
            _PassesTab(venueId: venue['venue_id'] as String, name: venue['name'] as String),
            _PeopleTab(venueId: venue['venue_id'] as String),
            _BarsTab(venueId: venue['venue_id'] as String),
          ]),
        ),
      );
}

class _TablesTab extends StatefulWidget {
  const _TablesTab({required this.venue});
  final Map<String, dynamic> venue;
  @override
  State<_TablesTab> createState() => _TablesTabState();
}

class _TablesTabState extends State<_TablesTab> {
  List<Map<String, dynamic>>? _t;
  late int? _cap = widget.venue['capacity'] as int?;
  String get _id => widget.venue['venue_id'] as String;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await VenueApi.tables(_id).catchError((_) => <Map<String, dynamic>>[]);
    if (mounted) setState(() => _t = t);
  }

  Future<void> _decide(Map<String, dynamic> t, String decision) async {
    int? size;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(decision == 'approve' ? 'Hold a table for ${t['party_size']}?' : decision == 'partial' ? 'Hold a smaller table' : 'Can\'t do it'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (decision == 'partial')
              Wrap(spacing: 6, children: [
                for (var n = 2; n < (t['party_size'] as int); n += (t['party_size'] as int) > 12 ? 2 : 1)
                  ChoiceChip(label: Text('$n'), selected: size == n, onSelected: (_) => set(() => size = n)),
              ]),
            TextField(controller: note, decoration: const InputDecoration(hintText: 'Note for them (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: decision == 'partial' && size == null ? null : () => Navigator.pop(ctx, true), child: const Text('SEND')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await VenueApi.decideTable(t['request_id'] as String, decision, size: size, note: note.text.trim().isEmpty ? null : note.text.trim());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          const Text('Room holds', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          DropdownButton<int?>(
            value: _cap,
            hint: const Text('not set'),
            items: [
              const DropdownMenuItem(value: null, child: Text('not set')),
              for (final n in const [20, 30, 40, 60, 80, 120, 200]) DropdownMenuItem(value: n, child: Text('$n people')),
            ],
            onChanged: (v) async {
              setState(() => _cap = v);
              await VenueApi.setCapacity(_id, v).catchError((_) {});
            },
          ),
        ]),
        const SizedBox(height: 8),
        if (t.isEmpty)
          Padding(
            padding: const EdgeInsets.all(30),
            child: Text('No table requests yet. Groups planning a night here can ask for one.',
                textAlign: TextAlign.center, style: TextStyle(color: B.muted)),
          ),
        for (final r in t)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: B.cardBox(border: r['status'] == 'pending' ? const Color(0x99F5C542) : null),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['party_size']} people · ${_when(r['starts_at'] as String)}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              Text('${r['requested_by']} · "${r['event_title'] ?? 'Plan'}" · ${r['going']} going so far', style: TextStyle(color: B.muted, fontSize: 13)),
              if (r['note'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('"${r['note']}"')),
              const SizedBox(height: 8),
              if (r['status'] == 'pending')
                Wrap(spacing: 8, children: [
                  FilledButton(onPressed: () => _decide(r, 'approve'), child: const Text('HOLD IT')),
                  OutlinedButton(onPressed: () => _decide(r, 'partial'), child: const Text('FEWER SEATS')),
                  TextButton(onPressed: () => _decide(r, 'decline'), child: const Text('CAN\'T')),
                ])
              else
                Text(
                  switch (r['status']) {
                    'approved' => 'Holding a table for ${r['approved_size']}',
                    'partial' => 'Holding ${r['approved_size']} of ${r['party_size']}',
                    _ => 'Declined',
                  },
                  style: TextStyle(color: B.accentStrong, fontWeight: FontWeight.w700),
                ),
            ]),
          ),
      ]),
    );
  }
}

class _PeopleTab extends StatefulWidget {
  const _PeopleTab({required this.venueId});
  final String venueId;
  @override
  State<_PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<_PeopleTab> {
  List<Map<String, dynamic>>? _p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await VenueApi.people(widget.venueId).catchError((_) => <Map<String, dynamic>>[]);
    if (mounted) setState(() => _p = p);
  }

  Future<void> _bar(Map<String, dynamic> p) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ask to bar ${p['name']}?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Based reviews every request. A first bar lasts 30 days; a second one here is indefinite. '
              'They\'re told the venue asked, not who.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 10),
          TextField(controller: reason, maxLines: 3, decoration: const InputDecoration(hintText: 'What happened?')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('SEND REQUEST')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final len = await VenueApi.requestBar(widget.venueId, p['user_id'] as String, reason.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Sent for review (${len == 'indefinite' ? 'indefinite, since this is a repeat' : '30 days'}).')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('People who checked in here or had plans here lately.', style: TextStyle(color: B.muted, fontSize: 13)),
        const SizedBox(height: 8),
        for (final x in p)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: x['user_id'] as String))),
              child: Avatar(path: x['photo'] as String?, size: 40),
            ),
            title: Text(x['name'] as String),
            subtitle: Text('${x['how']} · ${DateFormat('MMM d').format(DateTime.parse(x['last_seen'] as String).toLocal())}'),
            trailing: x['barred'] == true
                ? Text('BARRED', style: B.label.copyWith(color: B.urgent))
                : TextButton(onPressed: () => _bar(x), child: const Text('ASK TO BAR')),
          ),
      ]),
    );
  }
}

class _BarsTab extends StatelessWidget {
  const _BarsTab({required this.venueId});
  final String venueId;
  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: VenueApi.bars(venueId),
        builder: (context, snap) {
          final b = snap.data;
          if (b == null) return const Center(child: CircularProgressIndicator());
          if (b.isEmpty) return Center(child: Text('No bars.', style: TextStyle(color: B.muted)));
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final x in b)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${x['name']} · ${x['length'] == 'indefinite' ? 'indefinite' : '30 days'}'),
                subtitle: Text([
                  switch (x['status']) {
                    'pending' => 'Waiting for review',
                    'approved' => x['ends_at'] == null ? 'In place' : 'In place until ${DateFormat('MMM d').format(DateTime.parse(x['ends_at'] as String).toLocal())}',
                    'declined' => 'Not approved',
                    _ => 'Lifted',
                  },
                  if (x['appealed'] == true) 'appealed',
                  '"${x['reason']}"',
                ].join(' · ')),
              ),
          ]);
        },
      );
}

/// Passes: each venue gets a set number of one-time invite codes (100 to start) to hand out however
/// the owner likes — regulars, staff, a card on the bar. Someone who joins with one shows the venue badge.
class _PassesTab extends StatefulWidget {
  const _PassesTab({required this.venueId, required this.name});
  final String venueId;
  final String name;
  @override
  State<_PassesTab> createState() => _PassesTabState();
}

class _PassesTabState extends State<_PassesTab> {
  Map<String, dynamic>? _p;
  bool _busy = false;
  bool _showUsed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await VenueApi.passes(widget.venueId);
      if (mounted) setState(() => _p = p);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  Future<void> _make() async {
    final left = (_p?['left'] as num?)?.toInt() ?? 0;
    final options = <int>{...[5, 10, 25, 50].where((n) => n <= left), if (left < 50) left}.toList()..sort();
    final n = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Make passes', style: B.heading(20)), subtitle: Text('$left left. Each one lets one person in.')),
          for (final o in options) ListTile(title: Text('$o passes'), onTap: () => Navigator.pop(ctx, o)),
        ]),
      ),
    );
    if (n == null || n <= 0) return;
    setState(() => _busy = true);
    try {
      final codes = await VenueApi.createPasses(widget.venueId, n);
      await _load();
      if (mounted) _showSheet(codes);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
    if (mounted) setState(() => _busy = false);
  }

  String _sheetText(List<String> codes) => [
        'Based passes from ${widget.name}',
        'Get the app at based-social.com and enter your code. Each code works once.',
        '',
        ...codes,
      ].join('\n');

  void _showSheet(List<String> codes) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${codes.length} passes'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in codes) _PassCard(code: c, venue: widget.name),
            ]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _sheetText(codes)));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied. Paste into a doc to print.')));
            },
            child: const Text('COPY ALL'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('DONE')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) return const Center(child: CircularProgressIndicator());
    final codes = List<Map<String, dynamic>>.from(((p['codes'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final unused = codes.where((c) => c['used'] != true && c['active'] == true).toList();
    final used = codes.where((c) => c['used'] == true).toList();
    final left = (p['left'] as num?)?.toInt() ?? 0;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
            'Hand these out however you like: regulars, staff, a card by the till. '
            'Based is invite-only, so a pass from you is how people get in. '
            'Anyone who joins with one carries your badge.',
            style: TextStyle(color: B.muted, height: 1.4)),
        const SizedBox(height: 14),
        Row(children: [
          _Stat(n: '${p['allowance']}', label: 'total'),
          _Stat(n: '$left', label: 'not made yet'),
          _Stat(n: '${unused.length}', label: 'ready to give'),
          _Stat(n: '${p['joined']}', label: 'joined'),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy || left == 0 ? null : _make,
              icon: const Icon(Icons.confirmation_number_outlined, size: 18),
              label: Text(left == 0 ? 'ALL PASSES MADE' : 'MAKE PASSES'),
            ),
          ),
          if (unused.isNotEmpty) ...[
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _showSheet(unused.map((c) => c['code'] as String).toList()),
              child: const Text('PRINT SHEET'),
            ),
          ],
        ]),
        if (left == 0 && unused.isEmpty) ...[
          const SizedBox(height: 8),
          Text('That\'s all of them for now. Based may add more later.', style: TextStyle(color: B.muted, fontSize: 12.5)),
        ],
        const SizedBox(height: 18),
        if (unused.isNotEmpty) ...[
          const SectionLabel('Ready to give'),
          for (final c in unused)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c['code'] as String, style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.5)),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: c['code'] as String));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied.')));
                },
              ),
            ),
        ],
        if (used.isNotEmpty) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _showUsed = !_showUsed),
            child: Text(_showUsed ? 'Hide used passes' : 'Show ${used.length} used'),
          ),
          if (_showUsed)
            for (final c in used)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(c['code'] as String, style: TextStyle(color: B.muted, decoration: TextDecoration.lineThrough)),
                subtitle: c['joined'] == null ? null : Text('${c['joined']} joined'),
              ),
        ],
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.n, required this.label});
  final String n;
  final String label;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(n, style: B.heading(24)),
          Text(label, textAlign: TextAlign.center, style: TextStyle(color: B.muted, fontSize: 11.5)),
        ]),
      );
}

/// One pass as a little card (screenshot or print these).
class _PassCard extends StatelessWidget {
  const _PassCard({required this.code, required this.venue});
  final String code;
  final String venue;
  @override
  Widget build(BuildContext context) => Container(
        width: 160,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(border: Border.all(color: B.muted.withOpacity(0.4)), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('BASED', style: B.heading(14)),
          Text('a pass from $venue', style: TextStyle(color: B.muted, fontSize: 10.5)),
          const SizedBox(height: 6),
          SelectableText(code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
          Text('based-social.com', style: TextStyle(color: B.muted, fontSize: 10)),
        ]),
      );
}

/// You → Venue access: bars on you, and the appeal.
class MyBarsScreen extends StatefulWidget {
  const MyBarsScreen({super.key});
  @override
  State<MyBarsScreen> createState() => _MyBarsScreenState();
}

class _MyBarsScreenState extends State<MyBarsScreen> {
  late Future<List<Map<String, dynamic>>> _f = VenueApi.myBars();

  Future<void> _appeal(Map<String, dynamic> b) async {
    final t = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Appeal: ${b['venue']}'),
        content: TextField(controller: t, maxLines: 5, decoration: const InputDecoration(hintText: 'Tell us your side. A person reads every appeal.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('SEND')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await VenueApi.appeal(b['bar_id'] as String, t.text);
      setState(() => _f = VenueApi.myBars());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Venue access', style: B.heading(22))),
        body: FutureBuilder(
          future: _f,
          builder: (context, snap) {
            final b = snap.data;
            if (b == null) return const Center(child: CircularProgressIndicator());
            return ListView(padding: const EdgeInsets.all(18), children: [
              Text('Venues can ask Based to keep someone away after trouble. Every request is reviewed by a person. '
                  'Bars from 3 unrelated venues in a year show on your profile; they fade after 12 months or if an appeal succeeds.',
                  style: TextStyle(color: B.muted, fontSize: 13, height: 1.45)),
              const SizedBox(height: 14),
              if (b.isEmpty) Text('You\'re welcome everywhere.', style: TextStyle(color: B.ink2)),
              for (final x in b)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(x['venue'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(x['ends_at'] == null
                      ? 'Indefinite'
                      : 'Until ${DateFormat('MMM d').format(DateTime.parse(x['ends_at'] as String).toLocal())}'),
                  trailing: x['appealed'] == true
                      ? Text(x['decided_after_appeal'] == true ? 'APPEAL ANSWERED' : 'APPEAL SENT', style: B.label)
                      : TextButton(onPressed: () => _appeal(x), child: const Text('APPEAL')),
                ),
            ]);
          },
        ),
      );
}

/// Admin tab: venue applications, bar requests and appeals.
class AdminVenuesTab extends StatefulWidget {
  const AdminVenuesTab({super.key});
  @override
  State<AdminVenuesTab> createState() => _AdminVenuesTabState();
}

class _AdminVenuesTabState extends State<AdminVenuesTab> {
  List<Map<String, dynamic>> _apps = [];
  List<Map<String, dynamic>> _bars = [];
  List<Map<String, dynamic>> _venues = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([VenueApi.applications(), VenueApi.barRequests(), VenueApi.allVenues()]);
      if (mounted) setState(() { _apps = r[0]; _bars = r[1]; _venues = r[2]; });
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _editAllowance(Map<String, dynamic> v) async {
    final c = TextEditingController(text: '${v['pass_allowance']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Passes for ${v['name']}'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(helperText: '${v['passes_made']} already made · ${v['joined']} joined'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('SAVE')),
        ],
      ),
    );
    final n = int.tryParse(c.text.trim());
    if (ok != true || n == null) return;
    await VenueApi.setPassAllowance(v['venue_id'] as String, n).catchError((_) {});
    _load();
  }

  Future<void> _decideBar(Map<String, dynamic> b, String d) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(switch (d) { 'approve' => 'Approve bar', 'decline' => 'Decline', 'lift' => 'Lift the bar', _ => 'Keep the bar' }),
        content: TextField(controller: note, decoration: const InputDecoration(hintText: 'Note (only staff and admins see it)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CONFIRM')),
        ],
      ),
    );
    if (ok != true) return;
    await VenueApi.decideBar(b['bar_id'] as String, d, note: note.text.trim().isEmpty ? null : note.text.trim()).catchError((_) {});
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        const SectionLabel('Venue applications'),
        if (_apps.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text('None waiting.', style: TextStyle(color: B.muted))),
        for (final a in _apps)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${a['name']} · ${a['role']} of ${a['venue']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text([a['address'], a['note']].whereType<String>().join('\n')),
            isThreeLine: a['note'] != null,
            trailing: Wrap(spacing: 4, children: [
              IconButton(icon: const Icon(Icons.close), onPressed: () async { await VenueApi.decideApplication(a['id'] as int, false).catchError((_) {}); _load(); }),
              IconButton(icon: const Icon(Icons.check, color: B.gold), onPressed: () async { await VenueApi.decideApplication(a['id'] as int, true).catchError((_) {}); _load(); }),
            ]),
          ),
        const SizedBox(height: 18),
        const SectionLabel('Partner venues and passes'),
        if (_venues.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text('No venues yet.', style: TextStyle(color: B.muted))),
        for (final v in _venues)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(v['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${v['staff'] ?? 'no staff'} · ${v['passes_made']}/${v['pass_allowance']} passes made · ${v['joined']} joined'
                '${v['featured_until'] != null && DateTime.parse(v['featured_until'] as String).isAfter(DateTime.now()) ? ' · featured until ${DateFormat('MMM d').format(DateTime.parse(v['featured_until'] as String).toLocal())}' : ''}'),
            trailing: PopupMenuButton<String>(
              onSelected: (a) async {
                if (a == 'passes') return _editAllowance(v);
                await MembershipApi.setFeatured(v['venue_id'] as String, int.parse(a)).catchError((_) {});
                _load();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'passes', child: Text('Change passes')),
                PopupMenuItem(value: '30', child: Text('Feature for 30 days')),
                PopupMenuItem(value: '90', child: Text('Feature for 90 days')),
                PopupMenuItem(value: '0', child: Text('Stop featuring')),
              ],
            ),
          ),
        const SizedBox(height: 18),
        const SectionLabel('Bar requests and appeals'),
        if (_bars.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text('None waiting.', style: TextStyle(color: B.muted))),
        for (final b in _bars)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: B.cardBox(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${b['venue']} → ${b['name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              Text('${b['length'] == 'indefinite' ? 'Indefinite (repeat)' : '30 days'} · asked by ${b['requested_by'] ?? 'staff'} · '
                  '${b['other_venues']} other venue group(s) this year',
                  style: TextStyle(color: B.muted, fontSize: 12.5)),
              const SizedBox(height: 6),
              Text('"${b['reason']}"'),
              if (b['appeal'] != null) ...[
                const SizedBox(height: 6),
                Text('APPEAL', style: B.label.copyWith(color: B.accentStrong)),
                Text('"${b['appeal']}"'),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: b['status'] == 'pending'
                  ? [
                      OutlinedButton(onPressed: () => _decideBar(b, 'decline'), child: const Text('DECLINE')),
                      FilledButton(onPressed: () => _decideBar(b, 'approve'), child: const Text('APPROVE')),
                    ]
                  : [
                      OutlinedButton(onPressed: () => _decideBar(b, 'uphold'), child: const Text('KEEP IT')),
                      FilledButton(onPressed: () => _decideBar(b, 'lift'), child: const Text('LIFT')),
                    ]),
            ]),
          ),
      ]),
    );
  }
}

/// On a plan pinned to a partner venue: ask for a table, and see the answer.
class TableRequestChip extends StatefulWidget {
  const TableRequestChip({super.key, required this.event});
  final Map<String, dynamic> event;
  @override
  State<TableRequestChip> createState() => _TableRequestChipState();
}

class _TableRequestChipState extends State<TableRequestChip> {
  Map<String, dynamic>? _s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await VenueApi.tableStatus(widget.event['event_id'] as String).catchError((_) => null);
    if (mounted) setState(() => _s = s);
  }

  Future<void> _ask() async {
    var party = (widget.event['going'] as int? ?? 2).clamp(2, 40).toInt();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Ask for a table'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(onPressed: party > 1 ? () => set(() => party--) : null, icon: const Icon(Icons.remove)),
              Text('$party people', style: B.heading(22)),
              IconButton(onPressed: party < 60 ? () => set(() => party++) : null, icon: const Icon(Icons.add)),
            ]),
            TextField(controller: note, decoration: const InputDecoration(hintText: 'Anything they should know? (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ASK')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await VenueApi.requestTable(widget.event['event_id'] as String, party, note: note.text.trim().isEmpty ? null : note.text.trim());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null || s['partner'] != true) return const SizedBox.shrink();
    final r = s['request'] == null ? null : Map<String, dynamic>.from(s['request'] as Map);
    if (r == null) {
      if (widget.event['mine'] != true) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: InkWell(onTap: _ask, child: Text('ASK FOR A TABLE', style: B.label.copyWith(color: B.accentStrong))),
      );
    }
    final text = switch (r['status']) {
      'pending' => 'Table for ${r['party_size']} requested',
      'approved' => 'Table held for ${r['approved_size']}',
      'partial' => 'Table held for ${r['approved_size']} of ${r['party_size']}',
      _ => 'No table that night',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        const Icon(Icons.table_restaurant_outlined, size: 15, color: B.gold),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: B.accentStrong))),
      ]),
    );
  }
}
