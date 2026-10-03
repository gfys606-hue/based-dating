import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';
import 'venue_screens.dart';

List<Map<String, dynamic>> _rows(dynamic res) =>
    List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

String _when(String iso) => DateFormat('MMM d, h:mm a').format(DateTime.parse(iso).toLocal());

const _catNames = {
  'harassment': 'Harassment',
  'threats': 'Threats',
  'fake_profile': 'Fake profile',
  'scam': 'Scam',
  'explicit': 'Explicit',
  'underage': 'Under 18?',
  'spam': 'Spam',
  'other': 'Other',
};

/// Admin only: reports and photo checks.
class AdminReviewScreen extends StatelessWidget {
  const AdminReviewScreen({super.key});
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Safety review', style: B.heading(22)),
            bottom: const TabBar(tabs: [Tab(text: 'Reports'), Tab(text: 'Photos'), Tab(text: 'Venues')]),
          ),
          body: const TabBarView(children: [_ReportsTab(), _PhotosTab(), AdminVenuesTab()]),
        ),
      );
}

class _ReportsTab extends StatefulWidget {
  const _ReportsTab();
  @override
  State<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<_ReportsTab> {
  List<Map<String, dynamic>>? _rowsData;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = _rows(await Api.db.rpc('admin_reports'));
      if (mounted) setState(() => _rowsData = r);
    } catch (_) {
      if (mounted) setState(() => _rowsData = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rowsData;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (rows.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('No open reports.', textAlign: TextAlign.center, style: TextStyle(color: B.muted))),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ReportDetail(userId: r['user_id'] as String)));
                _load();
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: B.cardBox(border: r['urgent'] == true ? B.urgent : null),
                child: Row(children: [
                  Avatar(path: r['photo'] as String?, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(width: 8),
                        if (r['urgent'] == true) Text('URGENT', style: B.label.copyWith(color: B.urgent)),
                        if (r['status'] != 'active') ...[
                          const SizedBox(width: 6),
                          Text((r['status'] as String).toUpperCase(), style: B.label.copyWith(color: B.muted)),
                        ],
                      ]),
                      Text(
                        '${r['reporters']} ${r['reporters'] == 1 ? 'person' : 'people'} · '
                        '${List<String>.from(r['categories'] as List).map((c) => _catNames[c] ?? c).join(', ')}',
                        style: TextStyle(color: B.muted, fontSize: 13),
                      ),
                      if ((r['past_actions'] as int? ?? 0) > 0)
                        Text('${r['past_actions']} earlier action(s)', style: TextStyle(color: B.accentStrong, fontSize: 12.5)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _ReportDetail extends StatefulWidget {
  const _ReportDetail({required this.userId});
  final String userId;
  @override
  State<_ReportDetail> createState() => _ReportDetailState();
}

class _ReportDetailState extends State<_ReportDetail> {
  Map<String, dynamic>? _d;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Api.db.rpc('admin_report_detail', params: {'p_user': widget.userId});
    if (mounted) setState(() => _d = Map<String, dynamic>.from(r as Map));
  }

  Future<void> _act(String action, String label, String hint) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(controller: note, maxLines: 3, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(label.toUpperCase())),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await Api.db.rpc('admin_moderate', params: {
        'p_user': widget.userId,
        'p_action': action,
        'p_note': note.text.trim().isEmpty ? null : note.text.trim(),
      });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final u = Map<String, dynamic>.from(d['user'] as Map);
    final reports = _rows(d['reports']);
    final actions = _rows(d['actions']);
    return Scaffold(
      appBar: AppBar(
        title: Text(u['name'] as String, style: B.heading(22)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: widget.userId))),
            child: const Text('PROFILE'),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          [
            'Status: ${u['status']}${u['pause_reason'] == null ? '' : ' (${u['pause_reason']})'}',
            'Joined ${DateFormat('MMM d, y').format(DateTime.parse(u['joined'] as String).toLocal())}',
            if (u['invited_by'] != null) 'Invited by ${u['invited_by']}',
            if (u['joined_via'] != null) 'Code: ${u['joined_via']}',
          ].join('\n'),
          style: TextStyle(color: B.ink2, height: 1.5),
        ),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : () => _act('dismiss', 'Dismiss', 'Why it\'s fine (only you see this)'), child: const Text('DISMISS')),
          OutlinedButton(onPressed: _busy ? null : () => _act('warn', 'Warn', 'Message they\'ll get (optional)'), child: const Text('WARN')),
          FilledButton(onPressed: _busy ? null : () => _act('suspend', 'Suspend', 'Reason they\'ll see'), child: const Text('SUSPEND')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: B.urgent),
            onPressed: _busy ? null : () => _act('ban', 'Ban', 'Reason (they\'re removed and their devices blocked)'),
            child: const Text('BAN', style: TextStyle(color: Colors.white)),
          ),
          if (u['status'] == 'suspended' || u['status'] == 'banned')
            TextButton(onPressed: _busy ? null : () => _act('reinstate', 'Reinstate', 'Why (only you see this)'), child: const Text('REINSTATE')),
        ]),
        const SizedBox(height: 20),
        const SectionLabel('Reports'),
        for (final r in reports)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: B.cardBox(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_catNames[r['category']] ?? r['category']} · from ${r['reporter'] ?? 'deleted account'}'
                  '${r['context'] == null ? '' : ' · ${r['context']}'}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${_when(r['created_at'] as String)} · ${r['status']}', style: TextStyle(color: B.muted, fontSize: 12.5)),
              if (r['details'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(r['details'] as String)),
              if (r['messages'] != null) ...[
                const SizedBox(height: 8),
                Text('CHAT (LAST 30)', style: B.label),
                for (final m in _rows(r['messages']))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${m['from']}: ${m['body']}${m['status'] == 'sent' ? '' : '  [${m['status']}]'}',
                        style: TextStyle(fontSize: 13, color: m['from'] == u['name'] ? B.ink : B.muted)),
                  ),
              ],
            ]),
          ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 20),
          const SectionLabel('History'),
          for (final a in actions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${a['action']}${a['note'] == null ? '' : ': ${a['note']}'}'),
              subtitle: Text('${_when(a['at'] as String)} · ${a['by'] ?? ''}'),
            ),
        ],
      ]),
    );
  }
}

class _PhotosTab extends StatefulWidget {
  const _PhotosTab();
  @override
  State<_PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<_PhotosTab> {
  List<Map<String, dynamic>>? _q;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = _rows(await Api.db.rpc('admin_photo_queue'));
      if (mounted) setState(() => _q = r);
    } catch (_) {
      if (mounted) setState(() => _q = []);
    }
  }

  Future<void> _decide(Map<String, dynamic> p, bool ok) async {
    setState(() => _q!.remove(p));
    try {
      await Api.db.rpc('admin_photo_decision', params: {'p_review': p['review_id'], 'p_ok': ok, 'p_note': null});
    } catch (_) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q;
    if (q == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Each photo must clearly be them. The first 3 need their face, alone, looking at the camera. Selfies must match their photos.',
            style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 12),
        if (q.isEmpty) Padding(padding: const EdgeInsets.all(30), child: Text('Nothing to check.', textAlign: TextAlign.center, style: TextStyle(color: B.muted))),
        for (final p in q)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: B.cardBox(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${p['name']} · ${p['kind'] == 'selfie' ? 'selfie' : 'photo ${p['photo_position'] ?? ''}'}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SizedBox(height: 280, child: _BucketPhoto(bucket: p['bucket'] as String, path: p['path'] as String?)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => _decide(p, false), child: const Text('REJECT'))),
                const SizedBox(width: 8),
                Expanded(child: FilledButton(onPressed: () => _decide(p, true), child: const Text('LOOKS GOOD'))),
              ]),
            ]),
          ),
      ]),
    );
  }
}

class _BucketPhoto extends StatelessWidget {
  const _BucketPhoto({required this.bucket, required this.path});
  final String bucket;
  final String? path;
  @override
  Widget build(BuildContext context) {
    if (path == null) return Container(color: B.fill, alignment: Alignment.center, child: const Text('No file'));
    return FutureBuilder<String>(
      future: Api.db.storage.from(bucket).createSignedUrl(path!, 600),
      builder: (context, snap) => snap.hasData
          ? ClipRRect(borderRadius: BorderRadius.circular(B.radius), child: Image.network(snap.data!, fit: BoxFit.contain))
          : Container(color: B.fill),
    );
  }
}
