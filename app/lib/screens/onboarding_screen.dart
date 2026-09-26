import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api.dart';

/// Onboarding — target under 3 minutes. No bio, pronouns, job, or height.
/// Steps: basics → selfie → photos → interests → 3 scenarios → availability → location → rules
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.existing, required this.onDone});
  final Map<String, dynamic>? existing;
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _busy = false;
  String? _error;

  // basics
  final _name = TextEditingController();
  DateTime? _birthdate;
  String _gender = 'man';
  final Set<String> _seeking = {'woman'};

  // photos
  bool _selfieOk = false;
  final Map<int, String> _photoState = {}; // position → 'approved' | 'pending' | reason

  // interests
  List<Map<String, dynamic>> _topics = [];
  final Set<int> _picked = {};

  // scenarios (never shown on profile)
  final Map<String, String> _answers = {};
  static const _scenarios = {
    'disagree': ('A friend disagrees with you on something big. You…', ['Debate it', 'Let it go', 'Change the subject']),
    'plans': ('Plans fall through last minute. You…', ['Make new ones', 'Enjoy the night in', 'Feel annoyed for a bit']),
    'conflict': ('Someone says something you find rude. You…', ['Call it out', 'Ignore it', 'Bring it up later']),
  };

  // availability
  static const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _slots = ['morning', 'afternoon', 'evening'];
  final Map<String, Set<String>> _avail = {};

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    if (p != null) {
      _name.text = p['display_name'] ?? '';
      _selfieOk = p['selfie_verified'] == true;
      _step = 1;
    }
    Api.topics().then((t) => setState(() => _topics = t));
    Api.myPhotos().then((photos) => setState(() {
          for (final ph in photos) {
            _photoState[ph['position'] as int] = ph['review_status'] == 'rejected'
                ? (ph['reject_reason'] as String? ?? 'Rejected')
                : ph['review_status'] as String;
          }
        }));
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() { _busy = true; _error = null; });
    try {
      await f();
    } catch (e) {
      setState(() => _error = e.toString().replaceAll(RegExp(r'^.*?Exception: '), ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _next() => setState(() => _step++);

  // ---------------- steps ----------------
  Widget _basics() => ListView(children: [
        _h('The basics'),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'First name')),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
              context: context,
              firstDate: DateTime(now.year - 90),
              lastDate: DateTime(now.year - 18, now.month, now.day),
              initialDate: DateTime(now.year - 25),
            );
            if (d != null) setState(() => _birthdate = d);
          },
          child: Text(_birthdate == null ? 'Birthday (18+)' : 'Born ${_birthdate!.toString().substring(0, 10)}'),
        ),
        const SizedBox(height: 16),
        const Text('I am a'),
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'man', label: Text('Man')), ButtonSegment(value: 'woman', label: Text('Woman'))],
          selected: {_gender},
          onSelectionChanged: (s) => setState(() => _gender = s.first),
        ),
        const SizedBox(height: 16),
        const Text('Looking for'),
        Wrap(spacing: 8, children: [
          for (final g in ['man', 'woman'])
            FilterChip(
              label: Text(g == 'man' ? 'Men' : 'Women'),
              selected: _seeking.contains(g),
              onSelected: (on) => setState(() => on ? _seeking.add(g) : _seeking.remove(g)),
            ),
        ]),
        _nextButton(
          enabled: _name.text.trim().isNotEmpty && _birthdate != null && _seeking.isNotEmpty,
          onPressed: () => _run(() async {
            await Api.saveBasics(name: _name.text.trim(), birthdate: _birthdate!, gender: _gender, seeking: _seeking.toList());
            _next();
          }),
        ),
      ]);

  Widget _selfie() => ListView(children: [
        _h('Quick selfie check'),
        const Text('Take a live selfie. We match it against your photos so everyone here is real. It\'s never shown on your profile.'),
        const SizedBox(height: 24),
        Icon(_selfieOk ? Icons.verified : Icons.face_retouching_natural, size: 96,
            color: _selfieOk ? Colors.green : null),
        const SizedBox(height: 24),
        FilledButton.tonal(
          onPressed: _busy ? null : () => _run(() async {
            final img = await ImagePicker().pickImage(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, imageQuality: 85);
            if (img == null) return;
            final res = await Api.uploadSelfie(await img.readAsBytes());
            setState(() { _selfieOk = res['ok'] == true; _error = res['reason'] as String?; });
          }),
          child: Text(_selfieOk ? 'Retake' : 'Take selfie'),
        ),
        _nextButton(enabled: _selfieOk, onPressed: _next),
      ]);

  Widget _photos() {
    final approvedRequired = [1, 2, 3].every((p) => _photoState[p] == 'approved');
    return ListView(children: [
      _h('Your photos'),
      const Text('Photos 1–3: just you, looking at the camera, face clear.\n'
          'Photos 4–6 (optional): any shot of you — action, distance, facing away.\n'
          'No food, scenery, pets on their own, or memes.'),
      const SizedBox(height: 16),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [for (var i = 1; i <= 6; i++) _photoTile(i)],
      ),
      _nextButton(enabled: approvedRequired, onPressed: _next),
    ]);
  }

  Widget _photoTile(int pos) {
    final s = _photoState[pos];
    final color = s == 'approved' ? Colors.green : s == null ? Colors.grey : s == 'pending' ? Colors.orange : Colors.red;
    return InkWell(
      onTap: _busy ? null : () => _run(() async {
        final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600);
        if (img == null) return;
        setState(() => _photoState[pos] = 'pending');
        final res = await Api.uploadPhoto(pos, await img.readAsBytes());
        setState(() => _photoState[pos] = res['approved'] == true
            ? 'approved'
            : res['status'] == 'pending_review' ? 'pending' : (res['reason'] as String? ?? 'Rejected'));
      }),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: color, width: 2), borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(6),
        child: Center(
          child: Text(
            s == null ? (pos <= 3 ? '$pos\nRequired' : '$pos\nOptional') : s == 'approved' ? '✓' : s == 'pending' ? 'Checking…' : s,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _interests() => ListView(children: [
        _h('Pick 5+ interests'),
        const Text('This seeds your feed and your first matches.'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in _topics)
            FilterChip(
              label: Text(t['name'] as String),
              selected: _picked.contains(t['id']),
              onSelected: (on) => setState(() => on ? _picked.add(t['id'] as int) : _picked.remove(t['id'])),
            ),
        ]),
        _nextButton(
          enabled: _picked.length >= 5,
          onPressed: () => _run(() async { await Api.setTopics(_picked); _next(); }),
        ),
      ]);

  Widget _scenarioStep() => ListView(children: [
        _h('Three quick ones'),
        const Text('No right answers. Never shown on your profile.'),
        for (final e in _scenarios.entries) ...[
          const SizedBox(height: 16),
          Text(e.value.$1, style: const TextStyle(fontWeight: FontWeight.w600)),
          Wrap(spacing: 8, children: [
            for (final o in e.value.$2)
              ChoiceChip(label: Text(o), selected: _answers[e.key] == o, onSelected: (_) => setState(() => _answers[e.key] = o)),
          ]),
        ],
        _nextButton(
          enabled: _answers.length == _scenarios.length,
          onPressed: () => _run(() async { await Api.updateProfile({'scenario_answers': _answers}); _next(); }),
        ),
      ]);

  Widget _availability() => ListView(children: [
        _h('When are you usually free?'),
        const Text('Helps line up call times.'),
        const SizedBox(height: 12),
        for (final d in _days)
          Row(children: [
            SizedBox(width: 48, child: Text(d.toUpperCase())),
            for (final s in _slots)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(s),
                  selected: _avail[d]?.contains(s) ?? false,
                  onSelected: (on) => setState(() {
                    final set = _avail.putIfAbsent(d, () => {});
                    on ? set.add(s) : set.remove(s);
                  }),
                ),
              ),
          ]),
        _nextButton(
          enabled: _avail.values.any((s) => s.isNotEmpty),
          onPressed: () => _run(() async {
            await Api.updateProfile({'availability': {for (final e in _avail.entries) e.key: e.value.toList()}});
            _next();
          }),
        ),
      ]);

  Widget _location() => ListView(children: [
        _h('Your location'),
        const Text('We show the closest people first, then widen out step by step: 10 km, 15 km, 25 km and beyond. '
            'Your exact location is never shown to anyone.'),
        const SizedBox(height: 24),
        _nextButton(
          label: 'Share location',
          onPressed: () => _run(() async {
            var perm = await Geolocator.checkPermission();
            if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
            if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
              throw Exception('Location is required to find people near you.');
            }
            final pos = await Geolocator.getCurrentPosition();
            await Api.updateProfile({'lat': pos.latitude, 'lng': pos.longitude});
            _next();
          }),
        ),
      ]);

  Widget _rules() => ListView(children: [
        _h('How Based works'),
        _rule('Talk to your matches', 'People who actually engage get seen. People who collect matches and ghost slowly stop being shown.'),
        _rule('3 days to get a call in', 'Every match needs a 5-minute voice or video call within 3 days. You get 2 reschedules per match.'),
        _rule('Not feeling it? Just say so', 'One tap ends a match politely. It never counts against you.'),
        _rule('Contact info comes later', 'Phone numbers unlock after a video call and one message from each of you.'),
        _rule('Be real', 'Photos must be you. No bios, no filters, no pretending.'),
        _nextButton(
          label: 'I\'m in',
          onPressed: () => _run(() async {
            await Api.completeOnboarding();
            widget.onDone();
          }),
        ),
      ]);

  // ---------------- helpers ----------------
  Widget _h(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(s, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      );

  Widget _rule(String title, String body) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(body),
      );

  Widget _nextButton({bool enabled = true, required VoidCallback onPressed, String label = 'Next'}) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: FilledButton(onPressed: enabled && !_busy ? onPressed : null, child: Text(label)),
      );

  @override
  Widget build(BuildContext context) {
    final steps = [_basics, _selfie, _photos, _interests, _scenarioStep, _availability, _location, _rules];
    return Scaffold(
      appBar: AppBar(
        leading: _step > 0 ? BackButton(onPressed: () => setState(() => _step--)) : null,
        title: LinearProgressIndicator(value: (_step + 1) / steps.length),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(children: [
            Expanded(child: steps[_step]()),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
    );
  }
}
