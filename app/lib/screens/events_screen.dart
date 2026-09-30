import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api.dart';
import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

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
          const Expanded(child: Text('When are you usually free?', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
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
                        borderRadius: BorderRadius.circular(5),
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
                    style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
                Text('${at.day}', style: B.display(26).copyWith(color: Colors.white)),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (e['circle_name'] != null || e['topic'] != null)
                    Text(((e['circle_name'] ?? e['topic']) as String).toUpperCase(), style: B.label.copyWith(color: B.accent)),
                  Text(e['title'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(meta, style: TextStyle(color: B.muted, fontSize: 13)),
                  if (e['details'] != null) ...[
                    const SizedBox(height: 6),
                    Text(e['details'] as String, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: B.ink2)),
                  ],
                  const SizedBox(height: 10),
                  Row(children: [
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
    setState(() { _busy = true; _error = null; });
    try {
      await SocialApi.createEvent(
        title: _title.text.trim(),
        startsAt: _when,
        place: _place.text.trim().isEmpty ? null : _place.text.trim(),
        details: _details.text.trim().isEmpty ? null : _details.text.trim(),
        circleId: widget.circleId,
        capacity: _capacity,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = e.toString().contains('future') ? 'Pick a time in the future.' : 'Couldn\'t create it. Try again.'; });
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
        TextField(controller: _place, decoration: const InputDecoration(hintText: 'Where? (optional)')),
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
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: B.urgent))),
        const SizedBox(height: 14),
        FilledButton(onPressed: _busy ? null : _create, child: Text(_busy ? 'Creating…' : 'Create')),
      ]),
    );
  }
}
