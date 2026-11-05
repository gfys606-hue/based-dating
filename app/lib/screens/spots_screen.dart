import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/nights_api.dart';
import '../services/places_api.dart';
import '../services/social_api.dart';
import '../services/venue_api.dart';
import '../theme.dart';
import '../widgets/place_widgets.dart';
import '../widgets/ui.dart';
import 'music_screen.dart';
import 'profile_view_screen.dart';
import '../services/rooms_api.dart';
import '../brand.dart';

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
  List<Map<String, dynamic>> _rooms = [];
  List<Map<String, dynamic>> _plans = []; // where members plan to go, tonight and the next two nights
  int _planNight = 0; // 0 tonight, 1 tomorrow, 2 the night after
  Map<String, dynamic>? _recap; // last night, to look back on
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
    try {
      final r = await RoomsApi.mine();
      if (mounted) setState(() => _rooms = r);
    } catch (_) {}
    try {
      final r = await Future.wait([NightsApi.plans(days: 3), NightsApi.recap().then((v) => v == null ? <Map<String, dynamic>>[] : [v])]);
      if (mounted) {
        setState(() {
          _plans = r[0];
          _recap = r[1].isEmpty ? null : r[1].first;
        });
      }
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

          // ---- The morning after: how was it? ----
          if (_recap != null) ...[
            _NightRecapCard(
              recap: _recap!,
              onDone: (msg) {
                setState(() => _recap = null);
                if (msg != null) _toast(msg);
              },
            ),
            const SizedBox(height: 18),
          ],

          // ---- Here now ----
          SectionLabel('Here now', color: B.accentStrong),
          const SizedBox(height: 10),
          if (mine != null) _myCheckin(mine) else _checkinButton(),
          const SizedBox(height: 12),
          if (_rooms.isNotEmpty) ...[
            SectionLabel('Same room', color: B.accentStrong),
            const SizedBox(height: 4),
            Text('Members checked in where you are. Say yes and if they do too, you both see who it is.',
                style: TextStyle(color: B.muted, fontSize: 12.5)),
            const SizedBox(height: 8),
            for (final r in _rooms) _roomCard(r),
            const SizedBox(height: 12),
          ],
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

          // ---- Plans around town ----
          _plansSection(),
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
            Text('They work with ${appName}: ask for a table when your herd heads out.',
                style: TextStyle(color: B.muted, fontSize: 12.5)),
            const SizedBox(height: 6),
            for (final p in _partners)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.verified_outlined, color: B.goldInk),
                title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text([
                  if (p['featured'] == true) 'Featured',
                  if (p['perk'] != null) 'Tonight: ${p['perk']}',
                  if (p['nights'] != null) p['nights'] as String,
                  '${(p['distance_km'] as num? ?? 0).toStringAsFixed(1)} km',
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

  // Where members plan to go. Friends going are named; everyone else is just part of the number.
  Widget _plansSection() {
    final today = DateTime.now().subtract(const Duration(hours: 6)); // a night runs until 6 am
    final nights = [for (var i = 0; i < 3; i++) DateFormat('yyyy-MM-dd').format(today.add(Duration(days: i)))];
    final rows = _plans.where((p) => p['night'] == nights[_planNight]).toList();
    final pins = [
      for (final p in rows)
        if (p['lat'] != null && ((p['going'] as num? ?? 0) > 0 || p['perk'] != null))
          {
            'lat': p['lat'],
            'lng': p['lng'],
            'label': (p['going'] as num? ?? 0) > 0 ? '${p['going']} going' : 'Perk',
          },
    ];
    String dayLabel(int i) => switch (i) {
          0 => 'Tonight',
          1 => 'Tomorrow',
          _ => DateFormat('EEEE').format(today.add(Duration(days: i))),
        };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel('Plans around town', color: B.accentStrong),
      const SizedBox(height: 4),
      Text('How many members plan to be where. Your friends are named; everyone else is just a number.',
          style: TextStyle(color: B.muted, fontSize: 12.5)),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: Segmented(
          options: [for (var i = 0; i < 3; i++) dayLabel(i)],
          index: _planNight,
          onChanged: (i) => setState(() => _planNight = i),
        ),
      ),
      const SizedBox(height: 10),
      if (pins.isNotEmpty) ...[
        PlaceMap(height: 210, zoom: 13, pins: pins),
        const SizedBox(height: 8),
      ],
      if (rows.isEmpty && !_loading)
        Text('No plans posted for ${dayLabel(_planNight).toLowerCase()} yet. Post one from your spots below.',
            style: TextStyle(color: B.muted, fontSize: 13)),
      for (final p in rows) _planTile(p),
    ]);
  }

  Widget _planTile(Map<String, dynamic> p) {
    final going = (p['going'] as num? ?? 0).toInt();
    final friends = List<Map<String, dynamic>>.from(
        (p['friends'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final names = friends.map((f) => f['name'] as String).toList();
    final others = going - names.length - (p['me_going'] == true ? 1 : 0);
    final who = [
      if (p['me_going'] == true) 'You',
      ...names.take(3),
      if (names.length > 3) '${names.length - 3} more friends',
      if (others > 0) '$others ${others == 1 ? 'other member' : 'other members'}',
    ];
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: B.cardBox(border: p['perk'] != null ? B.gold : null),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 48,
          child: Column(children: [
            Text('$going', style: B.display(26).copyWith(color: going > 0 ? B.goldInk : B.muted)),
            Text('GOING', style: B.label.copyWith(fontSize: 8.5)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
              if (p['partner'] == true) ...[
                const SizedBox(width: 6),
                Icon(Icons.verified_outlined, size: 15, color: B.goldInk),
              ],
            ]),
            if (who.isNotEmpty)
              Text(who.join(', '), style: TextStyle(color: B.ink2, fontSize: 13)),
            if (p['nights'] != null)
              Text(p['nights'] as String, style: TextStyle(color: B.muted, fontSize: 12)),
            if (p['perk'] != null) ...[
              const SizedBox(height: 6),
              Wrap(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: B.gold, borderRadius: BorderRadius.circular(2)),
                  child: Text('MEMBERS: ${(p['perk'] as String).toUpperCase()}',
                      style: B.label.copyWith(color: B.onGold, fontSize: 9.5)),
                ),
              ]),
              if (p['perk_details'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(p['perk_details'] as String, style: TextStyle(color: B.muted, fontSize: 12.5)),
                ),
            ],
          ]),
        ),
      ]),
    );
  }

  Future<void> _answerRoom(Map<String, dynamic> r, bool yes) async {
    try {
      final both = await RoomsApi.answer(r['id'] as String, yes);
      if (both) _toast('You both said yes. Go say hi.');
    } catch (e) {
      _toast('That one has passed.');
    }
    _load();
  }

  Future<void> _followup(Map<String, dynamic> r, bool met, bool friend) async {
    try {
      final res = await RoomsApi.followup(r['id'] as String, met: met, friend: friend);
      _toast(res == 'friends' ? 'You\'re friends now.' : 'Thanks. Saved.');
    } catch (_) {}
    _load();
  }

  /// A same-room heads-up: partial profile (age + interests) until you both say yes.
  Widget _roomCard(Map<String, dynamic> r) {
    final shared = (r['shared'] as List? ?? const []).cast<String>();
    final interests = (r['interests'] as List? ?? const []).cast<String>();
    final matched = r['matched'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: B.cardBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (matched) ...[Avatar(path: r['other_photo'] as String?, size: 40), const SizedBox(width: 10)]
            else ...[
              CircleAvatar(radius: 20, backgroundColor: B.fill, child: Icon(Icons.question_mark, color: B.muted, size: 18)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                matched ? '${r['other_name']}, ${r['other_age']} · at ${r['place']}' : 'Someone, ${r['other_age']} · at ${r['place']}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in interests)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: shared.contains(t) ? B.accentSoft : B.fill,
                  borderRadius: BorderRadius.circular(B.radius),
                  border: shared.contains(t) ? Border.all(color: B.accent) : null,
                ),
                child: Text(t, style: TextStyle(fontSize: 12, fontWeight: shared.contains(t) ? FontWeight.w700 : FontWeight.w500)),
              ),
          ]),
          if (shared.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('You\'re both into ${shared.join(', ')}', style: TextStyle(color: B.goldInk, fontSize: 12.5)),
            ),
          const SizedBox(height: 8),
          if (!matched && r['my_answer'] == null)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => _answerRoom(r, false), child: const Text('Not tonight')),
              const SizedBox(width: 6),
              FilledButton(onPressed: () => _answerRoom(r, true), child: const Text('I\'D SAY HI')),
            ])
          else if (!matched)
            Text('You said yes. If they do too, you\'ll both see who it is.', style: TextStyle(color: B.muted, fontSize: 12.5))
          else if (r['ask_followup'] == true)
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Did you meet?', style: TextStyle(color: B.ink2, fontWeight: FontWeight.w700)),
              OutlinedButton(onPressed: () => _followup(r, false, false), child: const Text('We didn\'t')),
              OutlinedButton(onPressed: () => _followup(r, true, false), child: const Text('Yes')),
              FilledButton(onPressed: () => _followup(r, true, true), child: const Text('YES, LET\'S BE FRIENDS')),
            ])
          else
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ProfileViewScreen(userId: r['other_id'] as String),
                )),
                child: const Text('SEE PROFILE · ADD FRIEND'),
              ),
            ]),
        ]),
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
        Icon(Icons.my_location, color: B.goldInk),
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
        IconButton(
          tooltip: 'Music here tonight',
          icon: Icon(Icons.queue_music, color: B.goldInk),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => VenueMusicScreen(placeName: m['place_name'] as String),
          )),
        ),
        TextButton(
          onPressed: () async {
            await PlacesApi.checkOut().catchError((_) {});
            _load();
          },
          child: Text('I LEFT', style: B.label.copyWith(color: B.goldInk)),
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


/// The morning after: "You were at X last night. How was it? Did you meet anybody? Any pictures?"
/// No list of people. The answer becomes a rating for the night (two kinds of night, three answers each).
class _NightRecapCard extends StatefulWidget {
  const _NightRecapCard({required this.recap, required this.onDone});
  final Map<String, dynamic> recap;
  final void Function(String? message) onDone;
  @override
  State<_NightRecapCard> createState() => _NightRecapCardState();
}

class _NightRecapCardState extends State<_NightRecapCard> {
  String? _track;
  String? _rating;
  bool? _met;
  bool _busy = false;

  String get _place => widget.recap['place_name'] as String;
  String get _when => widget.recap['last_night'] == true ? 'last night' : 'the other night';

  Future<void> _save() async {
    if (_track == null || _rating == null) return;
    setState(() => _busy = true);
    try {
      await NightsApi.rate(widget.recap['place_id'] as String, widget.recap['night'] as String, _track!, _rating!, met: _met);
      widget.onDone(_met == true
          ? 'Thanks. If you met someone, find them in Friends and add them.'
          : 'Thanks. That helps other members find good nights.');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(NightsApi.errorText(e))));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _skip() async {
    await NightsApi.skip(widget.recap['place_id'] as String, widget.recap['night'] as String).catchError((_) {});
    widget.onDone(null);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: B.cardBox(border: B.gold),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('You were at $_place $_when.', style: B.heading(19))),
          IconButton(tooltip: 'Not now', onPressed: _busy ? null : _skip, icon: Icon(Icons.close, color: B.muted, size: 20)),
        ]),
        Text('How was it?', style: TextStyle(color: B.ink2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in nightTracks.entries)
            PillChip(
              label: t.value.$1,
              selected: _track == t.key,
              onTap: () => setState(() {
                _track = t.key;
                _rating = null;
              }),
            ),
        ]),
        if (_track != null) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final r in nightTracks[_track]!.$2)
              PillChip(label: r.$2, selected: _rating == r.$1, onTap: () => setState(() => _rating = r.$1)),
          ]),
        ],
        const SizedBox(height: 12),
        Text('Did you meet anybody?', style: TextStyle(color: B.ink2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, children: [
          PillChip(label: 'Yes', selected: _met == true, onTap: () => setState(() => _met = true)),
          PillChip(label: 'Not this time', selected: _met == false, onTap: () => setState(() => _met = false)),
        ]),
        const SizedBox(height: 10),
        Text('Any pictures you want to post? Share them from Discover → Posts. Ask before you post anyone else.',
            style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy || _rating == null ? null : _save,
          child: Text(_busy ? 'Saving…' : 'DONE'),
        ),
      ]),
    );
  }
}
