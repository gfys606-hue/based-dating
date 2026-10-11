import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/membership_api.dart';
import '../services/places_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

String _clean(Object e) {
  final s = e.toString();
  final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
  return (m?.group(1) ?? s.replaceFirst(RegExp(r'^(Exception|FunctionException)[^:]*: ?'), '')).trim();
}

/// You → Membership: Free, Plus, Inner.
class MembershipScreen extends StatefulWidget {
  const MembershipScreen({super.key});
  @override
  State<MembershipScreen> createState() => _MembershipScreenState();
}

class _MembershipScreenState extends State<MembershipScreen> with WidgetsBindingObserver {
  Map<String, dynamic>? _m;
  bool _yearly = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from the checkout page: check again
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final m = await MembershipApi.mine();
      if (mounted) setState(() => _m = m);
    } catch (_) {
      if (mounted) setState(() => _m = {'tier': 'free'});
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _travel() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _TravelSheet(),
    );
    if (done == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    final tier = m?['tier'] as String? ?? 'free';
    final open = m?['open'] == true;
    final canTravel = tier == 'inner' || !open; // free for everyone during early access
    final travel = m?['travel'] as Map?;
    final fmt = DateFormat('MMM d');
    String? when(String k) => m?[k] == null ? null : fmt.format(DateTime.parse(m![k] as String).toLocal());

    return Scaffold(
      appBar: AppBar(title: Text('Membership', style: B.heading(22))),
      body: m == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(18), children: [
                if (!open) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(B.radius)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Free during early access', style: B.heading(24).copyWith(color: Colors.white)),
                      const SizedBox(height: 4),
                      Text('50 Ouch picks a day, undo, and travel mode are on for you now. '
                          'Plans below are what\'s coming. Nothing is charged.',
                          style: TextStyle(color: B.onPanelMuted, height: 1.4)),
                    ]),
                  ),
                  const SizedBox(height: 18),
                ],
                if (tier != 'free') ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(B.radius)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tier == 'inner' ? 'You\'re Inner' : 'You\'re on Plus', style: B.heading(24).copyWith(color: Colors.white)),
                      const SizedBox(height: 4),
                      Text(
                        when('ends') != null
                            ? 'Ends ${when('ends')}. You keep everything until then.'
                            : when('renews') != null
                                ? 'Renews ${when('renews')}.'
                                : m['source'] == 'admin'
                                    ? 'On the house.'
                                    : '',
                        style: TextStyle(color: B.onPanelMuted),
                      ),
                      if (m['has_billing'] == true) ...[
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _run(MembershipApi.manage),
                          child: Text('CHANGE OR CANCEL', style: TextStyle(color: B.goldInk)),
                        ),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 18),
                ],
                if (canTravel) ...[
                  const SectionLabel('Travel mode'),
                  const SizedBox(height: 8),
                  if (travel != null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.flight_takeoff, color: B.goldInk),
                      title: Text('You\'re showing up in ${travel['name']}'),
                      subtitle: Text('Until ${fmt.format(DateTime.parse(travel['until'] as String).toLocal())}. Ouch, the feed and Spots use it.'),
                      trailing: TextButton(
                        onPressed: _busy ? null : () => _run(() async { await MembershipApi.endTravel(); await _load(); }),
                        child: const Text('END'),
                      ),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: _travel,
                      icon: const Icon(Icons.flight_takeoff),
                      label: const Text('I\'M HEADING SOMEWHERE'),
                    ),
                  const SizedBox(height: 22),
                ],
                Row(children: [
                  const Expanded(child: SectionLabel('Plans')),
                  Segmented(options: const ['Monthly', 'Yearly'], index: _yearly ? 1 : 0, onChanged: (i) => setState(() => _yearly = i == 1)),
                ]),
                const SizedBox(height: 10),
                _PlanCard(
                  name: 'Plus',
                  price: _yearly ? '\$39.99 / year' : '\$4.99 / month',
                  perks: const ['50 Ouch picks a day (free is 25)', 'Undo a pass'],
                  current: tier == 'plus',
                  included: tier == 'inner',
                  comingSoon: !open,
                  busy: _busy,
                  onTap: () => _run(() => MembershipApi.checkout('plus', yearly: _yearly)),
                ),
                const SizedBox(height: 12),
                _PlanCard(
                  name: 'Inner',
                  price: _yearly ? '\$119.99 / year' : '\$14.99 / month',
                  perks: const [
                    'Everything in Plus',
                    'Travel mode: show up in a city before you get there',
                    '2 extra personal invites every month',
                    'The Inner mark, which only other Inner members can see',
                  ],
                  current: tier == 'inner',
                  comingSoon: !open,
                  busy: _busy,
                  highlight: true,
                  onTap: () => _run(() => MembershipApi.checkout('inner', yearly: _yearly)),
                ),
                const SizedBox(height: 16),
                Text(
                  'Based has no ads. Partner venues you see are places that work with us. '
                  'Paying never changes who sees you or how you rank.',
                  style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4),
                ),
              ]),
            ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.name,
    required this.price,
    required this.perks,
    required this.current,
    required this.busy,
    required this.onTap,
    this.included = false,
    this.highlight = false,
    this.comingSoon = false,
  });
  final bool comingSoon;
  final String name;
  final String price;
  final List<String> perks;
  final bool current;
  final bool included;
  final bool busy;
  final bool highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: highlight
            ? B.cardBox().copyWith(border: Border.all(color: B.gold, width: 1.5))
            : B.cardBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(name, style: B.heading(24))),
            Text(price, style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          for (final p in perks)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.check, size: 16, color: B.goldInk)),
                const SizedBox(width: 8),
                Expanded(child: Text(p, style: const TextStyle(height: 1.35))),
              ]),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: current || included || comingSoon
                ? OutlinedButton(onPressed: null, child: Text(current ? 'YOUR PLAN' : included ? 'INCLUDED IN INNER' : 'COMING SOON'))
                : FilledButton(onPressed: busy ? null : onTap, child: Text('GET ${name.toUpperCase()}')),
          ),
        ]),
      );
}

/// Inner: pick a city and how long.
class _TravelSheet extends StatefulWidget {
  const _TravelSheet();
  @override
  State<_TravelSheet> createState() => _TravelSheetState();
}

class _TravelSheetState extends State<_TravelSheet> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic>? _pick;
  int _days = 7;
  Timer? _debounce;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), () async {
      try {
        final r = await PlacesApi.searchCity(v);
        if (mounted) setState(() { _results = r; _error = null; });
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    });
  }

  Future<void> _go() async {
    final p = _pick;
    if (p == null) return;
    setState(() => _busy = true);
    try {
      await MembershipApi.startTravel(p['lat'] as double, p['lng'] as double, p['name'] as String, _days);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { _error = _clean(e); _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Where are you headed?', style: B.heading(24)),
          const SizedBox(height: 4),
          Text('Ouch, the feed and Spots will act like you\'re there. Your friends still see you as you.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 12),
          if (_pick == null) ...[
            TextField(
              controller: _q,
              autofocus: true,
              onChanged: _changed,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'City'),
            ),
            for (final r in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r['name'] as String),
                subtitle: Text(r['address'] as String),
                onTap: () => setState(() => _pick = r),
              ),
          ] else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.place, color: B.goldInk),
              title: Text(_pick!['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(_pick!['address'] as String),
              trailing: TextButton(onPressed: () => setState(() => _pick = null), child: const Text('Change')),
            ),
            const SizedBox(height: 6),
            const SectionLabel('For'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final d in const [3, 7, 14, 30])
                PillChip(label: '$d days', selected: _days == d, onTap: () => setState(() => _days = d)),
            ]),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _go, child: Text(_busy ? 'Setting it…' : 'START TRAVEL MODE')),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        ]),
      );
}
