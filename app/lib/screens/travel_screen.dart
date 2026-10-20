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

/// Premium travel mode: pick any city, browse its spots and the members there, and say hi before you land.
/// The city you pick is where you're "standing" for intros: people only hear from you if it's inside their range.
class TravelScreen extends StatefulWidget {
  const TravelScreen({super.key});
  @override
  State<TravelScreen> createState() => _TravelScreenState();
}

class _TravelScreenState extends State<TravelScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _cities = [];
  Map<String, dynamic>? _city;
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _spots = [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () async {
      try {
        final r = await PlacesApi.searchCity(v);
        if (mounted) setState(() {
          _cities = r;
          _error = null;
        });
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    });
  }

  Future<void> _open(Map<String, dynamic> c) async {
    setState(() {
      _city = c;
      _loading = true;
      _error = null;
    });
    try {
      final lat = (c['lat'] as num).toDouble(), lng = (c['lng'] as num).toDouble();
      final r = await Future.wait([MembershipApi.travelPeople(lat, lng), MembershipApi.travelSpots(lat, lng)]);
      if (mounted) setState(() {
        _people = r[0];
        _spots = r[1];
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = _clean(e);
        _loading = false;
      });
    }
  }

  Future<void> _hi(Map<String, dynamic> p) async {
    final c = _city!;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _IntroSheet(person: p, city: c),
    );
    if (sent == true) _open(c);
  }

  @override
  Widget build(BuildContext context) {
    final c = _city;
    return Scaffold(
      appBar: AppBar(title: Text('Travel', style: B.heading(22))),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        if (c == null) ...[
          Text('Where are you headed?', style: B.display(28)),
          const SizedBox(height: 4),
          Text('Browse a city\'s spots and members before you get there, and say hi to people you\'d get along with.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 12),
          TextField(
            controller: _q,
            autofocus: true,
            onChanged: _changed,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'City'),
          ),
          for (final r in _cities)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.location_city, color: B.goldInk),
              title: Text(r['name'] as String),
              subtitle: Text(r['address'] as String),
              onTap: () => _open(r),
            ),
        ] else ...[
          Row(children: [
            Expanded(child: Text(c['name'] as String, style: B.display(28))),
            TextButton(onPressed: () => setState(() => _city = null), child: const Text('Change')),
          ]),
          Text('You\'re browsing as if you\'re here. Only people whose range covers this city can hear from you.',
              style: TextStyle(color: B.muted, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 16),
          if (_loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          if (!_loading) ...[
            SectionLabel('Spots', color: B.accentStrong),
            const SizedBox(height: 8),
            if (_spots.isEmpty) Text('No partner spots here yet.', style: TextStyle(color: B.muted)),
            for (final s in _spots)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(s['featured'] == true ? Icons.star : Icons.verified_outlined, color: B.goldInk),
                title: Text(s['name'] as String),
                subtitle: Text([if (s['address'] != null) s['address'], '${s['distance_km']} km from the centre'].join(' · ')),
              ),
            const SizedBox(height: 18),
            SectionLabel('Members here', color: B.accentStrong),
            const SizedBox(height: 8),
            if (_people.isEmpty) Text('No one here is taking traveller messages yet.', style: TextStyle(color: B.muted)),
            for (final p in _people)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: B.cardBox(),
                  child: Row(children: [
                    Avatar(path: p['photo'] as String?, size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${(p['name'] as String).split(' ').first}, ${p['age']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          (p['shared'] as List).isEmpty ? 'Different interests' : 'Both into ${(p['shared'] as List).join(', ')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: B.muted, fontSize: 12.5),
                        ),
                      ]),
                    ),
                    p['pending'] == true
                        ? Text('Said hi', style: TextStyle(color: B.muted, fontSize: 12))
                        : FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 12)),
                            onPressed: () => _hi(p),
                            child: const Text('SAY HI'),
                          ),
                  ]),
                ),
              ),
          ],
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: B.urgent))),
      ]),
    );
  }
}

class _IntroSheet extends StatefulWidget {
  const _IntroSheet({required this.person, required this.city});
  final Map<String, dynamic> person;
  final Map<String, dynamic> city;
  @override
  State<_IntroSheet> createState() => _IntroSheetState();
}

class _IntroSheetState extends State<_IntroSheet> {
  late final _body = TextEditingController(text: _draft());
  DateTime? _date;
  bool _busy = false;
  String? _error;

  String _draft() {
    final shared = (widget.person['shared'] as List).cast<String>();
    final into = shared.isEmpty ? '' : ' We\'re both into ${shared.take(2).join(' and ')}.';
    return 'I\'ll be in ${widget.city['name']} soon.$into Mind if I join you for a drink?';
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MembershipApi.sendIntro(widget.person['user_id'] as String, (widget.city['lat'] as num).toDouble(),
          (widget.city['lng'] as num).toDouble(), widget.city['name'] as String, _date, _body.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() {
        _error = _clean(e);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Say hi to ${(widget.person['name'] as String).split(' ').first}', style: B.heading(24)),
          const SizedBox(height: 4),
          Text('If they say yes, you\'re friends and can keep talking. If not, they won\'t hear from you again about it.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.event, size: 18),
            label: Text(_date == null ? 'When are you there? (optional)' : 'There on ${DateFormat('EEE MMM d').format(_date!)}'),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 180)), initialDate: now);
              if (d != null) setState(() => _date = d);
            },
          ),
          const SizedBox(height: 8),
          TextField(controller: _body, maxLines: 4, maxLength: 500, decoration: const InputDecoration(hintText: 'Your message')),
          if (_error != null) Text(_error!, style: TextStyle(color: B.urgent)),
          const SizedBox(height: 8),
          FilledButton(onPressed: _busy ? null : _send, child: Text(_busy ? 'Sending…' : 'SEND')),
        ]),
      );
}
