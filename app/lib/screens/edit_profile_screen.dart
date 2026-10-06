import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api.dart';
import '../services/city_api.dart';
import '../services/invites_api.dart';
import '../theme.dart';
import '../widgets/self_expression.dart';
import '../widgets/signed_photo.dart';
import '../widgets/ui.dart';
import 'unedited_screen.dart';

/// Edit profile: photos (replace, delete 4–6, reorder), name, interests, feed distance.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const _ranges = ['local', 'region', 'province', 'country', 'global'];
  static const _rangeLabels = ['Local', 'Region', 'Province', 'Country', 'Everywhere'];

  List<Map<String, dynamic>> _photos = [];
  List<Map<String, dynamic>> _topics = [];
  Set<int> _picked = {};
  final _name = TextEditingController();
  final _stance = TextEditingController();
  Map<String, dynamic>? _me; // my profile as others see it: voice, stance, lately
  String _range = 'global';
  List<Map<String, dynamic>> _cities = [];
  String? _city;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _stance.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    Future.wait([CityApi.open(), CityApi.mine()]).then((r) {
      if (mounted) {
        setState(() {
          _cities = r[0] as List<Map<String, dynamic>>;
          _city = (r[1] as Map<String, dynamic>?)?['slug'] as String?;
        });
      }
    }).catchError((_) {});
    try {
      final r = await Future.wait([Api.myProfile(), Api.myPhotos(), Api.topics(), Api.myTopicIds(), Api.profile(Api.me)]);
      if (!mounted) return;
      final p = r[0] as Map<String, dynamic>?;
      setState(() {
        _name.text = p?['display_name'] as String? ?? '';
        _range = p?['feed_range'] as String? ?? 'global';
        _photos = List<Map<String, dynamic>>.from(r[1] as List);
        _topics = List<Map<String, dynamic>>.from(r[2] as List);
        _picked = r[3] as Set<int>;
        _me = r[4] as Map<String, dynamic>?;
        _stance.text = (_me?['stance'] as Map?)?['statement'] as String? ?? '';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadMe() async {
    final me = await Api.profile(Api.me);
    if (mounted) setState(() => _me = me);
  }

  Future<void> _recordVoice() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const UneditedScreen()));
    if (saved == true) await _reloadMe();
  }

  Future<void> _saveStance() async {
    await _run(() async {
      await Api.setStance(_stance.text);
      await _reloadMe();
    }, done: _stance.text.trim().isEmpty ? 'Statement removed.' : 'Statement saved.');
  }

  Widget _selfExpression() {
    final voice = _me?['voice'] == null ? null : Map<String, dynamic>.from(_me!['voice'] as Map);
    final stance = _me?['stance'] == null ? null : Map<String, dynamic>.from(_me!['stance'] as Map);
    final lately = List<Map<String, dynamic>>.from(_me?['lately'] ?? const []);
    final nextAt = voice?['next_at'] == null ? null : DateTime.tryParse(voice!['next_at'] as String);
    final hoursLeft = nextAt == null ? 0 : nextAt.difference(DateTime.now()).inMinutes / 60;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Unedited
      if (voice != null)
        VoiceNoteCard(
          voice: voice,
          trailing: hoursLeft > 0
              ? Text('New question in ${hoursLeft.ceil()}h', style: TextStyle(color: B.muted, fontSize: 11.5))
              : TextButton(onPressed: _busy ? null : _recordVoice, child: const Text('New question')),
        )
      else
        Container(
          padding: const EdgeInsets.all(16),
          decoration: B.cardBox(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionLabel('Unedited', color: B.accentStrong),
            const SizedBox(height: 8),
            Text('Answer a question we pick, out loud.', style: B.heading(19)),
            const SizedBox(height: 6),
            Text('One take, up to 15 seconds, no re-recording. People hear how you actually talk.',
                style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _busy ? null : _recordVoice, icon: const Icon(Icons.mic), label: const Text('GET MY QUESTION')),
          ]),
        ),
      const SizedBox(height: 12),
      // Respectfully agree or disagree
      Container(
        padding: const EdgeInsets.all(16),
        decoration: B.cardBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel('Respectfully agree or disagree', color: B.accentStrong),
          const SizedBox(height: 6),
          Text('One thing you believe that people can disagree with, and you\'re fine with that.',
              style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 10),
          TextField(
            controller: _stance,
            maxLength: 140,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'e.g. A great breakfast beats a great dinner.'),
          ),
          if (stance != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${stance['agree'] ?? 0} agree · ${stance['disagree'] ?? 0} respectfully disagree · only you see this',
                  style: TextStyle(color: B.muted, fontSize: 12)),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              onPressed: _busy ? null : _saveStance,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
              child: const Text('SAVE STATEMENT'),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      // Lately (automatic)
      LatelyStrip(
        items: lately,
        emptyText: 'Fills in by itself from what you post, comment on and react to, and the events you go to. Nobody writes it, including you.',
      ),
      if (lately.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text('Filled in automatically from what you do on Based.', style: TextStyle(color: B.muted, fontSize: 12)),
      ],
    ]);
  }

  Future<void> _reloadPhotos() async {
    final ph = await Api.myPhotos();
    if (mounted) setState(() => _photos = ph);
  }

  Future<void> _run(Future<void> Function() f, {String? done}) async {
    setState(() => _busy = true);
    try {
      await f();
      if (done != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst(RegExp(r'^.*?(Exception|Error): '), '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg.isEmpty ? 'Something went wrong. Try again.' : msg)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  // ---------- photos ----------
  Future<void> _pickInto(int position) async {
    final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600);
    if (img == null) return;
    await _run(() async {
      final res = await Api.replacePhoto(position, await img.readAsBytes());
      await _reloadPhotos();
      if (res['approved'] == false && res['reason'] != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['reason'] as String)));
      }
    });
  }

  Future<void> _move(int index, int by) async {
    final ids = [for (final p in _photos) p['id'] as String];
    final j = index + by;
    if (j < 0 || j >= ids.length) return;
    final t = ids[index];
    ids[index] = ids[j];
    ids[j] = t;
    await _run(() async {
      await Api.reorderPhotos(ids);
      await _reloadPhotos();
    });
  }

  Future<void> _photoMenu(int index) async {
    final ph = _photos[index];
    final pos = ph['position'] as int;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Replace photo'), onTap: () => Navigator.pop(ctx, 'replace')),
          if (index > 0)
            ListTile(leading: const Icon(Icons.arrow_back), title: const Text('Move earlier'), onTap: () => Navigator.pop(ctx, 'left')),
          if (index < _photos.length - 1)
            ListTile(leading: const Icon(Icons.arrow_forward), title: const Text('Move later'), onTap: () => Navigator.pop(ctx, 'right')),
          if (pos >= 4)
            ListTile(
              leading: Icon(Icons.delete_outline, color: B.urgent),
              title: Text('Delete photo', style: TextStyle(color: B.urgent)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            )
          else
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Photos 1–3 can be replaced, not deleted'),
              subtitle: const Text('You always need 3 clear photos of just you.'),
              enabled: false,
            ),
        ]),
      ),
    );
    switch (choice) {
      case 'replace':
        await _pickInto(pos);
      case 'left':
        await _move(index, -1);
      case 'right':
        await _move(index, 1);
      case 'delete':
        await _run(() async {
          await Api.deletePhoto(ph['id'] as String);
          await _reloadPhotos();
        }, done: 'Photo deleted.');
    }
  }

  // ---------- save details ----------
  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || name.length > 40) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your name needs 1–40 characters.')));
      return;
    }
    if (_picked.length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick at least 5 interests.')));
      return;
    }
    await _run(() async {
      await Api.updateProfile({'display_name': name, 'feed_range': _range});
      await Api.setTopics(_picked);
      if (mounted) setState(() => _dirty = false);
    }, done: 'Saved.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Edit profile', style: B.heading(22))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 120),
                children: [
                  SectionLabel('Photos'),
                  const SizedBox(height: 6),
                  Text('Tap a photo to replace, move or delete it. Photos 1–3: just you, facing the camera. 4–6: any shot of you.',
                      style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
                  const SizedBox(height: 12),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.78,
                    children: [for (var slot = 1; slot <= 6; slot++) _slot(slot)],
                  ),
                  const SizedBox(height: 26),
                  SectionLabel('Show who you are'),
                  const SizedBox(height: 10),
                  _selfExpression(),
                  if (_me?['show_venue_badge'] != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _me!['show_venue_badge'] == true,
                      title: const Text('Show where I joined'),
                      subtitle: const Text('The "Joined through" badge from the venue that let you in'),
                      onChanged: (v) async {
                        setState(() => _me!['show_venue_badge'] = v);
                        try {
                          await InvitesApi.setShowBadge(v);
                        } catch (_) {}
                      },
                    ),
                  const SizedBox(height: 26),
                  SectionLabel('Name'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _name,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(hintText: 'First name', counterText: ''),
                    onChanged: (_) => setState(() => _dirty = true),
                  ),
                  const SizedBox(height: 22),
                  SectionLabel('Your city'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _cities.any((c) => c['slug'] == _city) ? _city : null,
                    isExpanded: true,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.place_outlined)),
                    hint: const Text('Pick a city'),
                    items: [
                      for (final c in _cities)
                        DropdownMenuItem(
                          value: c['slug'] as String,
                          child: Text([c['name'], c['region']].whereType<String>().join(', ')),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) {
                            if (v == null || v == _city) return;
                            final was = _city;
                            setState(() => _city = v);
                            _run(() async {
                              try {
                                await CityApi.set(v);
                              } catch (e) {
                                if (mounted) setState(() => _city = was);
                                rethrow;
                              }
                            }, done: 'City saved.');
                          },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _cities.length <= 1
                        ? 'Based is only in ${_cities.isEmpty ? 'one city' : _cities.first['name']} for now. More cities open as it grows.'
                        : 'Ouch shows you people in this city.',
                    style: TextStyle(color: B.muted, fontSize: 12.5),
                  ),
                  const SizedBox(height: 22),
                  SectionLabel('Feed distance'),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (var i = 0; i < _ranges.length; i++)
                      ChoiceChip(
                        label: Text(_rangeLabels[i]),
                        selected: _range == _ranges[i],
                        onSelected: (_) => setState(() {
                          _range = _ranges[i];
                          _dirty = true;
                        }),
                      ),
                  ]),
                  const SizedBox(height: 22),
                  Row(children: [
                    Expanded(child: SectionLabel('Interests')),
                    Text('${_picked.length} picked · 5+ needed', style: TextStyle(color: B.muted, fontSize: 12)),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final t in _topics)
                      FilterChip(
                        label: Text(t['name'] as String),
                        selected: _picked.contains(t['id']),
                        onSelected: (on) => setState(() {
                          on ? _picked.add(t['id'] as int) : _picked.remove(t['id']);
                          _dirty = true;
                        }),
                      ),
                  ]),
                ],
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: SafeArea(
                  top: false,
                  child: FilledButton(
                    onPressed: _busy || !_dirty ? null : _save,
                    child: Text(_busy ? 'SAVING…' : 'SAVE CHANGES'),
                  ),
                ),
              ),
              if (_busy) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
            ]),
    );
  }

  Widget _slot(int slot) {
    final i = _photos.indexWhere((p) => p['position'] == slot);
    if (i < 0) {
      // Only the next empty slot can be filled (photos stay in order with no gaps).
      final next = _photos.length + 1;
      final canAdd = slot == next;
      return InkWell(
        onTap: _busy || !canAdd ? null : () => _pickInto(slot),
        child: Container(
          decoration: BoxDecoration(
            color: B.fill,
            borderRadius: BorderRadius.circular(B.radius),
            border: Border.all(color: B.line),
          ),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add, color: canAdd ? B.accent : B.muted),
              const SizedBox(height: 4),
              Text(canAdd ? 'Add' : '$slot', style: TextStyle(fontSize: 12, color: B.muted)),
            ]),
          ),
        ),
      );
    }
    final ph = _photos[i];
    final status = ph['review_status'] as String? ?? 'pending';
    return InkWell(
      onTap: _busy ? null : () => _photoMenu(i),
      child: Stack(fit: StackFit.expand, children: [
        SignedPhoto(ph['storage_path'] as String?, radius: B.radius),
        Positioned(
          left: 6,
          top: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(2)),
            child: Text('$slot', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ),
        if (status != 'approved')
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 5),
              color: status == 'rejected' ? B.urgent : B.panel,
              child: Text(status == 'rejected' ? 'Not accepted — replace' : 'Checking…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: status == 'rejected' ? (B.isDark ? B.onGold : Colors.white) : Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
      ]),
    );
  }
}
