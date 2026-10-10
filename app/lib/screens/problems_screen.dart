import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../services/diagnostics.dart';
import '../theme.dart';

/// Admin → Activity → Problems: errors the app hit (grouped, with the screen they happened on)
/// and what testers reported with "Report a problem".
class ProblemsScreen extends StatefulWidget {
  const ProblemsScreen({super.key, this.startOnFeedback = false});
  final bool startOnFeedback;
  @override
  State<ProblemsScreen> createState() => _ProblemsScreenState();
}

class _ProblemsScreenState extends State<ProblemsScreen> {
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        initialIndex: widget.startOnFeedback ? 1 : 0,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Problems', style: B.heading(22)),
            bottom: const TabBar(tabs: [Tab(text: 'Errors'), Tab(text: 'Reports')]),
          ),
          body: const TabBarView(children: [_ErrorsTab(), _FeedbackTab()]),
        ),
      );
}

String _ago(String iso) {
  final t = DateTime.parse(iso).toLocal();
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return DateFormat('MMM d').format(t);
}

class _ErrorsTab extends StatefulWidget {
  const _ErrorsTab();
  @override
  State<_ErrorsTab> createState() => _ErrorsTabState();
}

class _ErrorsTabState extends State<_ErrorsTab> {
  List<Map<String, dynamic>>? _rows;
  bool _showFixed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Diagnostics.errors(resolved: _showFixed);
      if (mounted) setState(() => _rows = r);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Row(children: [
          Expanded(
            child: Text('Grouped by screen and message. Fixed ones reopen if they show up in a newer build.',
                style: TextStyle(color: B.muted, fontSize: 12.5)),
          ),
          TextButton(
            onPressed: () {
              setState(() => _showFixed = !_showFixed);
              _load();
            },
            child: Text(_showFixed ? 'HIDE FIXED' : 'SHOW FIXED'),
          ),
        ]),
        if (rows.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Center(child: Text('No errors. Nice.', style: TextStyle(color: B.muted)))),
        for (final e in rows)
          Container(
            margin: const EdgeInsets.only(top: 10),
            decoration: B.cardBox(),
            child: ExpansionTile(
              shape: const Border(),
              tilePadding: const EdgeInsets.symmetric(horizontal: 14),
              title: Text(e['message'] as String, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: e['resolved'] == true ? B.muted : null)),
              subtitle: Text(
                [
                  e['screen'],
                  '${e['count']}× · ${e['people']} ${e['people'] == 1 ? 'person' : 'people'}',
                  'last ${_ago(e['last_seen'] as String)}',
                  if (e['build'] != null) 'build ${e['build']}',
                  if (e['platform'] != null) e['platform'],
                ].join(' · '),
                style: TextStyle(color: B.muted, fontSize: 12),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              children: [
                if (e['stack'] != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(4)),
                    child: SelectableText(e['stack'] as String, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.35)),
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: '${e['screen']}\n${e['message']}\n\n${e['stack'] ?? ''}'));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied.')));
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('COPY'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      await Diagnostics.resolveError(e['fingerprint'] as String, e['resolved'] != true).catchError((_) {});
                      _load();
                    },
                    child: Text(e['resolved'] == true ? 'REOPEN' : 'MARK FIXED'),
                  ),
                ]),
              ],
            ),
          ),
      ]),
    );
  }
}

class _FeedbackTab extends StatefulWidget {
  const _FeedbackTab();
  @override
  State<_FeedbackTab> createState() => _FeedbackTabState();
}

class _FeedbackTabState extends State<_FeedbackTab> {
  List<Map<String, dynamic>>? _rows;
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Diagnostics.feedback(done: _showDone);
      if (mounted) setState(() => _rows = r);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Row(children: [
          Expanded(child: Text('From "Report a problem" in the app.', style: TextStyle(color: B.muted, fontSize: 12.5))),
          TextButton(
            onPressed: () {
              setState(() => _showDone = !_showDone);
              _load();
            },
            child: Text(_showDone ? 'HIDE DONE' : 'SHOW DONE'),
          ),
        ]),
        if (rows.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Center(child: Text('Nothing reported.', style: TextStyle(color: B.muted)))),
        for (final f in rows)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(14),
            decoration: B.cardBox(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _KindChip(f['kind'] as String),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${f['name'] ?? 'Someone'} · ${_ago(f['created_at'] as String)}',
                      style: TextStyle(color: B.muted, fontSize: 12.5)),
                ),
              ]),
              const SizedBox(height: 8),
              Text(f['body'] as String, style: TextStyle(height: 1.4, color: f['status'] == 'done' ? B.muted : null)),
              const SizedBox(height: 6),
              Text(
                [
                  if (f['screen'] != null) f['screen'],
                  if (f['build'] != null) 'build ${f['build']}',
                  if (f['platform'] != null) f['platform'],
                ].join(' · '),
                style: TextStyle(color: B.muted, fontSize: 12),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () async {
                    await Diagnostics.setFeedbackDone(f['id'] as String, f['status'] != 'done').catchError((_) {});
                    _load();
                  },
                  child: Text(f['status'] == 'done' ? 'REOPEN' : 'MARK DONE'),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip(this.kind);
  final String kind;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (kind) {
      'bug' => ('Something broke', const Color(0xFFD0453A)),
      'confusing' => ('Confusing', const Color(0xFFE0A526)),
      _ => ('Idea', const Color(0xFF2E9E5B)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}
