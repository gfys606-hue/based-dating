import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/places_api.dart';
import '../services/social_api.dart';
import '../services/venue_api.dart';
import '../theme.dart';
import '../widgets/place_widgets.dart';
import '../widgets/ui.dart';

/// Spots: who's out right now ("Here now"), and your watering holes.
/// Posting a night out from a saved spot is three taps: spot → time → send.
class SpotsScreen extends StatefulWidget {
  const SpotsScreen({super.key, required this.refresh});
  final ValueNotifier<int> refresh;
  @override
  State<SpotsScreen> createState() => _SpotsScreenState();
}

class _SpotsScreenState extends State<SpotsScreen> {
  List<Map<String, dynamic>> _here = [];
  List<Map<String, dynamic>> _spots = [];
  List<Map<String, dynamic>> _partners = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    await PlacesApi.refreshMyLocation();
    try {
      final r = await Future.wait([PlacesApi.hereNow(), PlacesApi.myPlaces()]);
      if (mounted) {
        setState(() {
          _here = r[0];
          _spots = r[1];
        });
      }
    } catch (_) {}
    try {
      final p = await VenueApi.partners();
      if (mounted) setState(() => _partners = p);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _addSpot() async {
    final p = await pickPlace(context, title: 'Add a spot');
    if (p == null) return;
    try {
      await PlacesApi.save(p['place_id'] as String, true);
    } catch (e) {
      _toast(e.toString().contains('20') ? 'You can keep up to 20 spots. Remove one first.' : 'Couldn\'t save it. Try again.');
    }
    _load();
  }

  Future<void> _removeSpot(Map<String, dynamic> s) async {
    await PlacesApi.save(s['place_id'] as String, false).catchError((_) {});
    _load();
  }

  Future<void> _hereNow([Map<String, dynamic>? spot]) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _HereNowSheet(spot: spot),
    );
    if (done == true) _load();
  }

  Future<void> _plan(Map<String, dynamic> spot) async {
    final made = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _QuickPlanSheet(spot: spot),
    );
    if (made == true) _toast('Sent. It\'s in Events, and the people you picked got a heads-up.');
  }

  @override
  Widget build(BuildContext context) {
    final mine = _here.where((h) => h['is_me'] == true).firstOrNull;
    final friends = _here.where((h) => h['is_me'] != true).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, B.navClearance),
        children: [
          Text('Spots', style: B.display(32)),
          const SizedBox(height: 4),
          Text('Where your people are tonight, and the places you keep going back to.',
              style: TextStyle(color: B.muted, fontSize: 13)),
          const SizedBox(height: 16),
          if (_loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),

          // ---- Here now ----
          SectionLabel('Here now', color: B.accentStrong),
          const SizedBox(height: 10),
          if (mine != null) _myCheckin(mine) else _checkinButton(),
          const SizedBox(height: 12),
          if (friends.isNotEmpty) ...[
            PlaceMap(
              height: 210,
              pins: [for (final f in friends) {'lat': f['lat'], 'lng': f['lng'], 'label': f['name']}],
            ),
            const SizedBox(height: 10),
            for (final f in friends) _friendHere(f),
          ] else if (!_loading)
            Text('None of your friends are checked in right now.', style: TextStyle(color: B.muted, fontSize: 13)),
          const SizedBox(height: 24),

          // ---- Watering holes ----
          Row(children: [
            Expanded(child: SectionLabel('Your spots', color: B.accentStrong)),
            TextButton.icon(onPressed: _addSpot, icon: const Icon(Icons.add, size: 18), label: const Text('Add a spot')),
          ]),
          const SizedBox(height: 6),
          if (_spots.isEmpty && !_loading)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: B.cardBox(),
              child: Text(
                'Save the places you keep going back to. Then posting a night out is three taps: spot, time, send.',
                textAlign: TextAlign.center,
                style: TextStyle(color: B.muted, height: 1.4),
              ),
            ),
          for (final s in _spots) _spotTile(s),

          // ---- Partner venues: places that work with Based (tables for your herd, passes for friends) ----
          if (_partners.isNotEmpty) ...[
            const SizedBox(height: 24),
            SectionLabel('Partner venues', color: B.accentStrong),
            const SizedBox(height: 4),
            Text('They work with Based: ask for a table when your herd heads out.',
                style: TextStyle(color: B.muted, fontSize: 12.5)),
            const SizedBox(height: 6),
            for (final p in _partners)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.verified_outlined, color: B.gold),
                title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text([
                  if (p['featured'] == true) 'Featured',
                  '${(p['distance_km'] as num).toStringAsFixed(1)} km',
                  if ((p['friends_here'] as num? ?? 0) > 0) '${p['friends_here']} friends here now',
                  if (p['address'] != null) p['address'] as String,
                ].join(' · ')),
                trailing: TextButton(onPressed: () => _plan(p), child: const Text('PLAN')),
              ),
          ],
        ],
      ),
    );
  }

  Widget _checkinButton() => FilledButton.icon(
        onPressed: () => _hereNow(),
        icon: const Icon(Icons.my_location),
        label: const Text('I\'M HERE NOW'),
      );

  Widget _myCheckin(Map<String, dynamic> m) {
    final until = DateTime.parse(m['until'] as String).toLocal();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(B.radius)),
      child: Row(children: [
        const Icon(Icons.my_location, color: B.gold),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('You\'re at ${m['place_name']}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            Text(
              '${m['audience'] == 'friends' ? 'Friends' : 'Your Tight'} can see it until ${DateFormat('h:mm a').format(until)}',
              style: TextStyle(color: B.onPanelMuted, fontSize: 12.5),
            ),
          ]),
        ),
        TextButton(
          onPressed: () async {
            await PlacesApi.checkOut().catchError((_) {});
            _load();
          },
          child: Text('I LEFT', style: B.label.copyWith(color: B.gold)),
        ),
      ]),
    );
  }

  Widget _friendHere(Map<String, dynamic> f) {
    final since = DateTime.parse(f['started_at'] as String).toLocal();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: B.cardBox(),
        child: Row(children: [
          Avatar(path: f['photo'] as String?, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${f['name']} · ${f['place_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                [
                  'since ${DateFormat('h:mm a').format(since)}',
                  if (f['distance_km'] != null) '${f['distance_km']} km away',
                ].join(' · '),
                style: TextStyle(color: B.muted, fontSize: 12.5),
              ),
            ]),
          ),
          DirectionsButton(lat: (f['lat'] as num).toDouble(), lng: (f['lng'] as num).toDouble(), compact: true),
        ]),
      ),
    );
  }

  Widget _spotTile(Map<String, dynamic> s) {
    final here = s['friends_here'] as int? ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
        decoration: B.cardBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s['name'] as String, style: B.heading(19)),
                Text(
                  [s['address'], if (s['distance_km'] != null) '${s['distance_km']} km'].whereType<String>().join(' · '),
                  style: TextStyle(color: B.muted, fontSize: 12.5),
                ),
                if (here > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(here == 1 ? '1 friend here now' : '$here friends here now',
                        style: TextStyle(color: B.accentStrong, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ),
              ]),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'remove') _removeSpot(s);
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Remove spot'))],
            ),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: () => _plan(s),
              icon: const Icon(Icons.send, size: 16),
              label: const Text('GOING'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: () => _hereNow(s),
              icon: const Icon(Icons.my_location, size: 16),
              label: const Text('HERE NOW'),
            ),
            DirectionsButton(lat: (s['lat'] as num).toDouble(), lng: (s['lng'] as num).toDouble(), compact: true),
          ]),
        ]),
      ),
    );
  }
}

/// "I'm here now": pick the spot (if not given), how long, and who sees it.
class _HereNowSheet extends StatefulWidget {
  const _HereNowSheet({this.spot});
  final Map<String, dynamic>? spot;
  @override
  State<_HereNowSheet> createState() => _HereNowSheetState();
}

class _HereNowSheetState extends State<_HereNowSheet> {
  late Map<String, dynamic>? _spot = widget.spot;
  int _hours = 3;
  String _audience = 'inner';
  bool _notify = true;
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    if (_spot == null) {
      setState(() => _error = 'Pick where you are.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PlacesApi.checkIn(_spot!['place_id'] as String, hours: _hours, audience: _audience, notify: _notify);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn\'t check in. Try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('I\'m here now', style: B.heading(24)),
          const SizedBox(height: 4),
          Text('Only the people you pick see it, it ends on its own, and quiet mode hides it.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () async {
              final p = await pickPlace(context, title: 'Where are you?');
              if (p != null) setState(() => _spot = p);
            },
            icon: const Icon(Icons.place_outlined),
            label: Text(_spot == null ? 'Pick where you are' : _spot!['name'] as String),
          ),
          const SizedBox(height: 14),
          const SectionLabel('For'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            for (final h in const [1, 3, 6])
              ChoiceChip(label: Text(h == 1 ? '1 hour' : '$h hours'), selected: _hours == h, onSelected: (_) => setState(() => _hours = h)),
          ]),
          const SizedBox(height: 12),
          const SectionLabel('Who sees it'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            ChoiceChip(label: const Text('Tight'), selected: _audience == 'inner', onSelected: (_) => setState(() => _audience = 'inner')),
            ChoiceChip(label: const Text('All friends'), selected: _audience == 'friends', onSelected: (_) => setState(() => _audience = 'friends')),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _notify,
            title: const Text('Let them know'),
            subtitle: const Text('Sends a notification. Off = they only see it if they look.'),
            onChanged: (v) => setState(() => _notify = v),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: TextStyle(color: B.urgent))),
          FilledButton(onPressed: _busy ? null : _go, child: Text(_busy ? 'Checking in…' : 'CHECK IN')),
        ]),
      ),
    );
  }
}

/// Three taps from a saved spot: pick a time, pick who sees it, send.
class _QuickPlanSheet extends StatefulWidget {
  const _QuickPlanSheet({required this.spot});
  final Map<String, dynamic> spot;
  @override
  State<_QuickPlanSheet> createState() => _QuickPlanSheetState();
}

class _QuickPlanSheetState extends State<_QuickPlanSheet> {
  late DateTime _when = _defaultTime();
  String _audience = 'inner';
  bool _busy = false;
  String? _error;

  static DateTime _defaultTime() {
    final n = DateTime.now();
    final tonight = DateTime(n.year, n.month, n.day, 21);
    return n.isBefore(tonight.subtract(const Duration(minutes: 30))) ? tonight : n.add(const Duration(minutes: 45));
  }

  List<(String, DateTime)> get _options {
    final n = DateTime.now();
    DateTime at(int dayOffset, int h) => DateTime(n.year, n.month, n.day + dayOffset, h);
    return [
      if (n.isBefore(at(0, 20).subtract(const Duration(minutes: 30)))) ('Tonight 8', at(0, 20)),
      if (n.isBefore(at(0, 21).subtract(const Duration(minutes: 30)))) ('Tonight 9', at(0, 21)),
      if (n.isBefore(at(0, 22).subtract(const Duration(minutes: 30)))) ('Tonight 10', at(0, 22)),
      ('In an hour', DateTime(n.year, n.month, n.day, n.hour + 1, n.minute < 30 ? 0 : 30)),
      ('Tomorrow 9', at(1, 21)),
    ];
  }

  Future<void> _custom() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 60)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (t == null) return;
    setState(() => _when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SocialApi.createEvent(
        title: widget.spot['name'] as String,
        startsAt: _when,
        placeId: widget.spot['place_id'] as String,
        audience: _audience,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().contains('testing')
            ? 'Plans are still in testing for your account.'
            : 'Couldn\'t send it. Try again.');
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel('Going to', color: B.accentStrong),
          Text(widget.spot['name'] as String, style: B.heading(26)),
          const SizedBox(height: 14),
          const SectionLabel('When'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final o in _options)
              ChoiceChip(label: Text(o.$1), selected: _when == o.$2, onSelected: (_) => setState(() => _when = o.$2)),
            ActionChip(
              avatar: const Icon(Icons.schedule, size: 16),
              label: Text(_options.any((o) => o.$2 == _when) ? 'Other…' : DateFormat('EEE h:mm a').format(_when)),
              onPressed: _custom,
            ),
          ]),
          const SizedBox(height: 12),
          const SectionLabel('Who sees it'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            ChoiceChip(label: const Text('Tight'), selected: _audience == 'inner', onSelected: (_) => setState(() => _audience = 'inner')),
            ChoiceChip(label: const Text('Friends'), selected: _audience == 'friends', onSelected: (_) => setState(() => _audience = 'friends')),
            ChoiceChip(label: const Text('Everyone nearby'), selected: _audience == 'public', onSelected: (_) => setState(() => _audience = 'public')),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: B.urgent))),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.send),
            label: Text(_busy ? 'Sending…' : 'SEND · ${DateFormat('EEE h:mm a').format(_when)}'),
          ),
        ]),
      ),
    );
  }
}
