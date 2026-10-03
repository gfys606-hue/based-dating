import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../services/friends_api.dart';
import '../services/places_api.dart';
import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/place_widgets.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// Events: your free time (used to match you with people and circles) and plans near you.
class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key});
  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  final _listKey = GlobalKey<EventsListState>();

  Future<void> _plan() async {
    final made = await showCreateEventSheet(context);
    if (made) _listKey.currentState?.load();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Row(children: [
                  Expanded(child: Text('Events', style: B.display(32))),
                  FilledButton.icon(onPressed: _plan, icon: const Icon(Icons.add, size: 18), label: const Text('Plan')),
                ]),
                const SizedBox(height: 14),
                const AvailabilityCard(),
                const SizedBox(height: 20),
                const SectionLabel('Coming up near you'),
              ]),
            ),
          ),
        ],
        body: EventsList(key: _listKey),
      ),
    );
  }
}

const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const _slots = ['morning', 'afternoon', 'evening'];

/// "When are you usually free?" A 7×3 grid saved to your profile.
/// Used under the hood to match people and circles with overlapping free time.
class AvailabilityCard extends StatefulWidget {
  const AvailabilityCard({super.key});
  @override
  State<AvailabilityCard> createState() => _AvailabilityCardState();
}

class _AvailabilityCardState extends State<AvailabilityCard> {
  final Map<String, Set<String>> _free = {for (final d in _days) d: <String>{}};
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    Api.myProfile().then((p) {
      final a = p?['availability'];
      if (a is Map && mounted) {
        setState(() {
          for (final d in _days) {
            final v = a[d];
            if (v is List) _free[d] = v.map((e) => e.toString()).toSet();
          }
        });
      }
    }).catchError((_) {});
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await SocialApi.saveAvailability({
        for (final d in _days)
          if (_free[d]!.isNotEmpty) d: _free[d]!.toList(),
      });
      if (mounted) setState(() => _dirty = false);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn\'t save. Try again.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: B.cardBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('When are you usually free?', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
          if (_dirty)
            TextButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const SizedBox(width: 30),
          for (final d in _days)
            Expanded(
              child: Text(d[0].toUpperCase() + d.substring(1, 2),
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: B.muted)),
            ),
        ]),
        for (final s in _slots)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              SizedBox(
                width: 30,
                child: Icon(
                  s == 'morning' ? Icons.wb_twilight : (s == 'afternoon' ? Icons.wb_sunny_outlined : Icons.nightlight_outlined),
                  size: 16,
                  color: B.muted,
                ),
              ),
              for (final d in _days)
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _free[d]!.contains(s) ? _free[d]!.remove(s) : _free[d]!.add(s);
                      _dirty = true;
                    }),
                    child: Container(
                      height: 28,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: _free[d]!.contains(s) ? B.accent : B.fill,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// Upcoming events near you, or for one circle when [circleId] is set.
class EventsList extends StatefulWidget {
  const EventsList({super.key, this.circleId});
  final String? circleId;
  @override
  State<EventsList> createState() => EventsListState();
}

class EventsListState extends State<EventsList> {
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final e = await SocialApi.events(circleId: widget.circleId);
      if (mounted) setState(() { _events = e; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rsvp(Map<String, dynamic> e, String status) async {
    try {
      await SocialApi.rsvp(e['event_id'] as String, e['my_rsvp'] == status ? 'none' : status);
      await load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(err.toString().contains('full') ? 'This event is full.' : 'Couldn\'t update. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (widget.circleId != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton.icon(
                onPressed: () async {
                  if (await showCreateEventSheet(context, circleId: widget.circleId)) load();
                },
                icon: const Icon(Icons.add),
                label: const Text('Plan something with this circle'),
              ),
            ),
          if (_events.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Text('Nothing planned yet. Start something.', textAlign: TextAlign.center, style: TextStyle(color: B.muted)),
            ),
          for (final e in _events) _card(e),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> e) {
    final at = DateTime.parse(e['starts_at'] as String).toLocal();
    final going = e['going'] as int? ?? 0;
    final cap = e['capacity'] as int?;
    final my = e['my_rsvp'] as String?;
    final meta = [
      DateFormat('EEE h:mm a').format(at),
      if (e['place_name'] != null) e['place_name'] as String,
      if (e['distance_km'] != null) '${e['distance_km']} km',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: B.cardBox(),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Date block on the left
            Container(
              width: 62,
              color: my == 'going' ? B.accent : B.panel,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(DateFormat('MMM').format(at).toUpperCase(),
                    style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700)),
                Text('${at.day}', style: B.display(26).copyWith(color: Colors.white)),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_audienceLabel(e) != null)
                    Text(_audienceLabel(e)!, style: B.label.copyWith(color: B.accent)),
                  Text(e['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(meta, style: TextStyle(color: B.muted, fontSize: 13)),
                  if (e['place_lat'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        if (e['place_address'] != null)
                          Text(e['place_address'] as String, style: TextStyle(color: B.muted, fontSize: 12)),
                        InkWell(
                          onTap: () => _showMap(e),
                          child: Text('MAP', style: B.label.copyWith(color: B.accentStrong)),
                        ),
                        InkWell(
                          onTap: () => PlacesApi.directions((e['place_lat'] as num).toDouble(), (e['place_lng'] as num).toDouble()),
                          child: Text('DIRECTIONS', style: B.label.copyWith(color: B.accentStrong)),
                        ),
                      ]),
                    ),
                  if (e['details'] != null) ...[
                    const SizedBox(height: 6),
                    Text(e['details'] as String, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: B.ink2)),
                  ],
                  const SizedBox(height: 10),
                  Row(children: [
                    if (my != null || e['mine'] == true)
                      InkWell(
                        onTap: () => _showPeople(e),
                        child: Text(cap == null ? '$going going  ›' : '$going / $cap going  ›',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: B.accentStrong)),
                      )
                    else
                      Text(cap == null ? '$going going' : '$going / $cap going',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    const Spacer(),
                    if (e['mine'] == true)
                      TextButton(
                        onPressed: () async {
                          await SocialApi.cancelEvent(e['event_id'] as String);
                          load();
                        },
                        child: Text('Cancel event', style: TextStyle(color: B.urgent)),
                      )
                    else ...[
                      _rsvpButton(e, 'maybe', 'Maybe'),
                      const SizedBox(width: 6),
                      _rsvpButton(e, 'going', 'Going'),
                    ],
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _showMap(Map<String, dynamic> e) => showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(e['place_name'] as String? ?? '', style: B.heading(22)),
              if (e['place_address'] != null) Text(e['place_address'] as String, style: TextStyle(color: B.muted)),
              const SizedBox(height: 12),
              PlaceMap(height: 260, pins: [
                {'lat': e['place_lat'], 'lng': e['place_lng'], 'label': e['place_name']}
              ]),
              const SizedBox(height: 12),
              DirectionsButton(lat: (e['place_lat'] as num).toDouble(), lng: (e['place_lng'] as num).toDouble()),
            ]),
          ),
        ),
      );

  /// Small label on the card: who the plan is for (or its circle / topic for open plans).
  String? _audienceLabel(Map<String, dynamic> e) {
    final from = e['mine'] == true ? 'You' : (e['creator_name'] as String? ?? '');
    switch (e['audience']) {
      case 'inner':
        return e['mine'] == true ? 'YOUR INNER CIRCLE' : '${from.toUpperCase()} · INNER CIRCLE';
      case 'friends':
        return e['mine'] == true ? 'YOUR FRIENDS' : '${from.toUpperCase()} · FRIENDS';
      case 'custom':
        return e['mine'] == true ? 'INVITED · ${e['invited_count'] ?? ''}' : '${from.toUpperCase()} INVITED YOU';
    }
    final l = (e['circle_name'] ?? e['topic']) as String?;
    return l?.toUpperCase();
  }

  /// Who's going (only shown once you've RSVP'd), so you can find and add people you met there.
  Future<void> _showPeople(Map<String, dynamic> e) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .7),
          child: FutureBuilder(
            future: FriendsApi.eventPeople(e['event_id'] as String),
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
              }
              final people = snap.data ?? const [];
              return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(18, 18, 18, 12), children: [
                Text(e['title'] as String, style: B.heading(22)),
                const SizedBox(height: 4),
                Text('Tap someone to see their profile or add them as a friend.', style: TextStyle(color: B.muted, fontSize: 13)),
                const SizedBox(height: 10),
                for (final p in people)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Avatar(path: p['photo'] as String?, size: 40),
                    title: Text(p['user_id'] == Api.me ? '${p['name']} (you)' : p['name'] as String),
                    subtitle: Text(p['rsvp'] == 'going' ? 'Going' : 'Maybe'),
                    onTap: p['user_id'] == Api.me
                        ? null
                        : () => Navigator.of(ctx).push(
                            MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: p['user_id'] as String))),
                  ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _rsvpButton(Map<String, dynamic> e, String status, String label) {
    final on = e['my_rsvp'] == status;
    return on
        ? FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 14)),
            onPressed: () => _rsvp(e, status),
            child: Text(label))
        : OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 14)),
            onPressed: () => _rsvp(e, status),
            child: Text(label));
  }
}

/// Bottom sheet to plan an event. Returns true if one was created.
Future<bool> showCreateEventSheet(BuildContext context, {String? circleId}) async {
  final made = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _CreateEventSheet(circleId: circleId),
  );
  return made == true;
}

class _CreateEventSheet extends StatefulWidget {
  const _CreateEventSheet({this.circleId});
  final String? circleId;
  @override
  State<_CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<_CreateEventSheet> {
  final _title = TextEditingController();
  final _place = TextEditingController();
  final _details = TextEditingController();
  DateTime _when = DateTime.now().add(const Duration(days: 1)).copyWith(hour: 18, minute: 0, second: 0, millisecond: 0, microsecond: 0);
  int? _capacity;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _venue; // picked from OpenStreetMap / saved spots
  String _audience = 'public'; // public | friends | inner | custom (circle plans always go to the circle)
  final Set<String> _picked = {};
  List<Map<String, dynamic>>? _friends;

  Future<void> _pickPeople() async {
    _friends ??= await FriendsApi.friends().catchError((_) => <Map<String, dynamic>>[]);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .7),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(18, 18, 18, 12), children: [
              Text('Who\'s invited', style: B.heading(22)),
              const SizedBox(height: 6),
              if (_friends!.isEmpty) Text('Add friends first, then you can invite them here.', style: TextStyle(color: B.muted)),
              for (final f in _friends!)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _picked.contains(f['user_id']),
                  secondary: Avatar(path: f['photo'] as String?, size: 36),
                  title: Text(f['name'] as String),
                  subtitle: f['is_inner'] == true ? const Text('Inner circle') : null,
                  onChanged: (v) => set(() => v == true ? _picked.add(f['user_id'] as String) : _picked.remove(f['user_id'])),
                ),
              const SizedBox(height: 8),
              FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('DONE')),
            ]),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _pickWhen() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 180)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (t == null) return;
    setState(() => _when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _create() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Give it a name.');
      return;
    }
    if (widget.circleId == null && _audience == 'custom' && _picked.isEmpty) {
      setState(() => _error = 'Pick at least one friend.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await SocialApi.createEvent(
        title: _title.text.trim(),
        startsAt: _when,
        place: _venue != null ? null : (_place.text.trim().isEmpty ? null : _place.text.trim()),
        placeId: _venue?['place_id'] as String?,
        details: _details.text.trim().isEmpty ? null : _details.text.trim(),
        circleId: widget.circleId,
        capacity: _capacity,
        audience: widget.circleId != null ? 'circle' : _audience,
        invitees: _audience == 'custom' && widget.circleId == null ? _picked.toList() : null,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      final msg = e.toString();
      setState(() {
        _busy = false;
        _error = msg.contains('future')
            ? 'Pick a time in the future.'
            : msg.contains('at least one') || msg.contains('only invite')
                ? 'Pick at least one friend.'
                : 'Couldn\'t create it. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.circleId == null ? 'Plan something' : 'Plan with your circle', style: B.heading(22)),
        const SizedBox(height: 14),
        TextField(controller: _title, decoration: const InputDecoration(hintText: 'What? (e.g. Sunday fishing at Sheep River)')),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _pickWhen,
          icon: const Icon(Icons.schedule),
          label: Text(DateFormat('EEE, MMM d · h:mm a').format(_when)),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final p = await pickPlace(context);
            if (p != null) setState(() => _venue = p);
          },
          icon: Icon(_venue == null ? Icons.place_outlined : Icons.location_on, color: _venue == null ? null : B.gold),
          label: Text(_venue == null ? 'Pick the place (exact pin)' : '${_venue!['name']}'),
        ),
        if (_venue == null) ...[
          const SizedBox(height: 6),
          TextField(controller: _place, decoration: const InputDecoration(hintText: 'Or just type where (optional)')),
        ],
        const SizedBox(height: 10),
        TextField(controller: _details, maxLines: 3, decoration: const InputDecoration(hintText: 'Details (optional)')),
        const SizedBox(height: 10),
        Row(children: [
          const Text('Spots', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(spacing: 6, children: [
              for (final c in const [null, 4, 8, 12, 20])
                ChoiceChip(
                  label: Text(c == null ? 'No limit' : '$c'),
                  selected: _capacity == c,
                  onSelected: (_) => setState(() => _capacity = c),
                ),
            ]),
          ),
        ]),
        if (widget.circleId == null) ...[
          const SizedBox(height: 14),
          const SectionLabel('Who sees it'),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in const [('public', 'Everyone nearby'), ('friends', 'Friends'), ('inner', 'Inner circle'), ('custom', 'Pick people')])
              ChoiceChip(
                label: Text(a.$1 == 'custom' && _picked.isNotEmpty ? 'Picked (${_picked.length})' : a.$2),
                selected: _audience == a.$1,
                onSelected: (_) {
                  setState(() => _audience = a.$1);
                  if (a.$1 == 'custom') _pickPeople();
                },
              ),
          ]),
          const SizedBox(height: 6),
          Text(
            switch (_audience) {
              'friends' => 'All your friends see it and get a heads-up.',
              'inner' => 'Only your inner circle sees it and gets a heads-up.',
              'custom' => 'Only the people you pick see it and get a heads-up.',
              _ => 'Anyone nearby can find it. Nobody gets pinged.',
            },
            style: TextStyle(color: B.muted, fontSize: 12.5),
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: B.urgent))),
        const SizedBox(height: 14),
        FilledButton(onPressed: _busy ? null : _create, child: Text(_busy ? 'Creating…' : 'Create')),
      ]),
    );
  }
}
