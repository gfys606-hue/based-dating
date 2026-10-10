import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/activity_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'admin_review_screen.dart';

/// Admin → Activity: are people using it, are they connecting, and where do they get stuck.
/// Everything comes from one server call that only admins can make.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});
  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ActivityApi.dashboard();
      if (mounted) setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t load activity. Pull to try again.');
    }
  }

  int _n(Map m, String k) => (m[k] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      appBar: AppBar(
        title: Text('Activity', style: B.heading(22)),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: d == null
            ? ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: TextStyle(color: B.muted))),
                ),
              ])
            : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: _body(d)),
      ),
    );
  }

  List<Widget> _body(Map<String, dynamic> d) {
    final pulse = Map<String, dynamic>.from(d['pulse'] as Map);
    final daily = List<Map<String, dynamic>>.from(((d['daily'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final funnel = Map<String, dynamic>.from(d['funnel'] as Map);
    final conn = List<Map<String, dynamic>>.from(((d['connecting'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final stuck = Map<String, dynamic>.from(d['stuck'] as Map);
    final since = pulse['tracking_since'] == null ? null : DateTime.parse(pulse['tracking_since'] as String);
    final today = DateTime.parse(d['today'] as String);
    final dau = _n(pulse, 'dau'), mau = _n(pulse, 'mau');
    final newNow = _n(pulse, 'new_7d'), newBefore = _n(pulse, 'new_prev_7d');

    return [
      if (since != null && today.difference(since).inDays < 14)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('Daily activity is tracked from ${DateFormat('MMM d').format(since)}, so early days look light.',
              style: TextStyle(color: B.muted, fontSize: 12.5)),
        ),
      // ---------- pulse ----------
      const SectionLabel('Pulse'),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth > 560 ? 3 : 2;
        final tiles = [
          _Tile('Members', '${_n(pulse, 'members')}', '${_n(pulse, 'onboarding')} still signing up'),
          _Tile('Active today', '$dau', mau == 0 ? 'nobody this month yet' : '${(100 * dau / mau).round()}% of this month\'s'),
          _Tile('This week', '${_n(pulse, 'wau')}', 'opened the app'),
          _Tile('This month', '$mau', 'opened the app'),
          _Tile('New this week', '$newNow', _delta(newNow, newBefore, 'vs last week')),
          _Tile('Waitlist', '${_n(pulse, 'waitlist')}', 'waiting for a code'),
        ];
        final w = (c.maxWidth - 10 * (cols - 1)) / cols;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
      }),
      const SizedBox(height: 22),

      // ---------- 14 days ----------
      const SectionLabel('Last 14 days'),
      const SizedBox(height: 4),
      Row(children: [
        _Key(color: B.accentStrong, label: 'Active'),
        const SizedBox(width: 14),
        _Key(color: B.gold, label: 'Joined'),
      ]),
      const SizedBox(height: 8),
      Container(
        height: 170,
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
        decoration: B.cardBox(),
        child: CustomPaint(size: Size.infinite, painter: _DailyChart(daily, ink: B.muted, active: B.accentStrong, joined: B.gold)),
      ),
      const SizedBox(height: 22),

      // ---------- funnel ----------
      const SectionLabel('Signup funnel'),
      const SizedBox(height: 2),
      Text('Everyone who joined in the last 30 days, and how far they got.', style: TextStyle(color: B.muted, fontSize: 12.5)),
      const SizedBox(height: 10),
      ..._funnel(funnel),
      const SizedBox(height: 22),

      // ---------- connecting ----------
      const SectionLabel('Connecting'),
      const SizedBox(height: 2),
      Text('Last 7 days, compared with the 7 before.', style: TextStyle(color: B.muted, fontSize: 12.5)),
      const SizedBox(height: 6),
      Container(
        decoration: B.cardBox(),
        child: Column(children: [
          for (var i = 0; i < conn.length; i++) ...[
            if (i > 0) Divider(height: 1, color: B.fill),
            _ConnRow(label: conn[i]['label'] as String, now: _n(conn[i], 'now'), before: _n(conn[i], 'before')),
          ],
        ]),
      ),
      const SizedBox(height: 22),

      // ---------- stuck ----------
      const SectionLabel('Where people get stuck'),
      const SizedBox(height: 6),
      Container(
        decoration: B.cardBox(),
        child: Column(children: [
          _StuckRow(
              'Ouch matches that ended without a call',
              _n(stuck, 'matches_expired_7d'),
              _n(stuck, 'matches_7d') == 0 ? 'this week' : 'this week · ${_n(stuck, 'matches_7d')} new matches'),
          Divider(height: 1, color: B.fill),
          _StuckRow('Friend requests waiting 3+ days', _n(stuck, 'requests_waiting_3d'), 'nobody answered'),
          Divider(height: 1, color: B.fill),
          _StuckRow('Stuck signing up 2+ days', _n(stuck, 'stuck_onboarding'), 'never finished their profile'),
          Divider(height: 1, color: B.fill),
          _StuckRow('Paused for photos', _n(stuck, 'photos_paused'), 'need 3 clear photos'),
          Divider(height: 1, color: B.fill),
          _StuckRow('Open reports', _n(stuck, 'reports_open'), 'tap to review',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminReviewScreen()))),
          Divider(height: 1, color: B.fill),
          _StuckRow('Codes never used (7+ days old)', _n(stuck, 'codes_never_used'), 'handed out but nobody joined'),
        ]),
      ),
    ];
  }

  String _delta(int now, int before, String suffix) {
    if (before == 0) return now == 0 ? 'none last week either' : 'none last week';
    final pct = ((now - before) * 100 / before).round();
    return '${pct >= 0 ? '+' : ''}$pct% $suffix';
  }

  List<Widget> _funnel(Map<String, dynamic> f) {
    final steps = [
      ('Signed up', 'signed_up'),
      ('Used an invite code', 'used_code'),
      ('Finished their profile', 'profile_done'),
      ('Made a connection', 'connected'),
      ('Sent a message', 'messaged'),
      ('Came back another day', 'came_back'),
    ];
    final top = math.max(1, _n(f, 'signed_up'));
    return [
      for (final (label, key) in steps)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
              Text('${_n(f, key)}', style: const TextStyle(fontWeight: FontWeight.w700)),
              SizedBox(
                width: 48,
                child: Text('${(100 * _n(f, key) / top).round()}%', textAlign: TextAlign.right, style: TextStyle(color: B.muted, fontSize: 12.5)),
              ),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: _n(f, key) / top,
                minHeight: 7,
                backgroundColor: B.fill,
                color: B.accentStrong,
              ),
            ),
          ]),
        ),
    ];
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.sub);
  final String label, value, sub;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: B.cardBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: B.label),
          const SizedBox(height: 4),
          Text(value, style: B.display(30)),
          const SizedBox(height: 2),
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: B.muted, fontSize: 12)),
        ]),
      );
}

class _Key extends StatelessWidget {
  const _Key({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: B.muted, fontSize: 12.5)),
      ]);
}

class _ConnRow extends StatelessWidget {
  const _ConnRow({required this.label, required this.now, required this.before});
  final String label;
  final int now, before;
  @override
  Widget build(BuildContext context) {
    final diff = now - before;
    final color = diff > 0 ? const Color(0xFF2E9E5B) : diff < 0 ? const Color(0xFFD0453A) : B.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(children: [
        Expanded(child: Text(label)),
        Text('$now', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        SizedBox(
          width: 64,
          child: Text(diff == 0 ? '—' : '${diff > 0 ? '▲' : '▼'} ${diff.abs()}',
              textAlign: TextAlign.right, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class _StuckRow extends StatelessWidget {
  const _StuckRow(this.label, this.count, this.sub, {this.onTap});
  final String label, sub;
  final int count;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        onTap: onTap,
        title: Text(label, style: const TextStyle(fontSize: 14.5)),
        subtitle: Text(sub, style: TextStyle(color: B.muted, fontSize: 12.5)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: count > 0 ? const Color(0xFFE0A526).withOpacity(0.18) : B.fill,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text('$count', style: TextStyle(fontWeight: FontWeight.w700, color: count > 0 ? const Color(0xFFB07A10) : B.muted)),
        ),
      );
}

/// Bars for people active each day, dots for people who joined.
class _DailyChart extends CustomPainter {
  _DailyChart(this.days, {required this.ink, required this.active, required this.joined});
  final List<Map<String, dynamic>> days;
  final Color ink, active, joined;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    const labelH = 16.0;
    final h = size.height - labelH;
    final maxV = days.fold<int>(1, (m, d) => math.max(m, math.max((d['active'] as num).toInt(), (d['joined'] as num).toInt())));
    final slot = size.width / days.length;
    final barW = math.max(4.0, slot * 0.55);
    final grid = Paint()
      ..color = ink.withOpacity(0.18)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h), Offset(size.width, h), grid);
    // top value
    final tp = TextPainter(text: TextSpan(text: '$maxV', style: TextStyle(color: ink, fontSize: 10)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, const Offset(0, -2));
    canvas.drawLine(Offset(tp.width + 4, 4), Offset(size.width, 4), grid..color = ink.withOpacity(0.08));
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      final cx = slot * i + slot / 2;
      final a = (d['active'] as num).toDouble();
      final j = (d['joined'] as num).toDouble();
      final top = h - (h - 6) * a / maxV;
      canvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTRB(cx - barW / 2, top, cx + barW / 2, h),
              topLeft: const Radius.circular(2), topRight: const Radius.circular(2)),
          Paint()..color = active.withOpacity(a > 0 ? 0.85 : 0.0));
      if (j > 0) canvas.drawCircle(Offset(cx, h - (h - 6) * j / maxV), 3.2, Paint()..color = joined);
      final day = DateTime.parse(d['day'] as String);
      if (i == days.length - 1 || i % 2 == 1) {
        final lp = TextPainter(
            text: TextSpan(text: i == days.length - 1 ? 'Today' : DateFormat('d').format(day), style: TextStyle(color: ink, fontSize: 9.5)),
            textDirection: TextDirection.ltr)
          ..layout();
        lp.paint(canvas, Offset(cx - lp.width / 2, h + 3));
      }
    }
  }

  @override
  bool shouldRepaint(_DailyChart old) => old.days != days;
}
