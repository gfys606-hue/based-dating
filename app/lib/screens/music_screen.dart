import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/music_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';

String _clean(Object e) {
  final s = e.toString();
  final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
  return (m?.group(1) ?? s.replaceFirst(RegExp(r'^(Exception|FunctionException)[^:]*: ?'), '')).trim();
}

/// One preview plays at a time across the whole music screen.
class _Player {
  static final player = AudioPlayer();
  static final playing = ValueNotifier<String?>(null); // "kind:id"
  static bool _wired = false;

  static Future<void> toggle(String key, Future<String?> Function() url) async {
    if (!_wired) {
      _wired = true;
      player.onPlayerComplete.listen((_) => playing.value = null);
    }
    if (playing.value == key) {
      await player.stop();
      playing.value = null;
      return;
    }
    await player.stop();
    final u = await url();
    if (u == null) throw 'No preview for this one.';
    playing.value = key;
    await player.play(UrlSource(u));
  }

  static Future<void> stop() async {
    await player.stop();
    playing.value = null;
  }
}

/// Music at the place you're checked in: suggest songs or albums, vote tonight's list up or down.
/// Staff open it with [placeId] + [staff] to see the ranked requests and have the final say.
class VenueMusicScreen extends StatefulWidget {
  const VenueMusicScreen({super.key, required this.placeName, this.placeId, this.staff = false});
  final String placeName;
  final String? placeId;
  final bool staff;
  @override
  State<VenueMusicScreen> createState() => _VenueMusicScreenState();
}

class _VenueMusicScreenState extends State<VenueMusicScreen> {
  List<Map<String, dynamic>> _list = [];
  int _left = 0;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _Player.stop();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final r = await Future.wait([
        MusicApi.tonight(placeId: widget.placeId),
        if (!widget.staff) MusicApi.left(),
      ]);
      if (!mounted) return;
      setState(() {
        _list = r[0] as List<Map<String, dynamic>>;
        if (!widget.staff) _left = r[1] as int;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (!quiet) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
  }

  Future<void> _vote(Map<String, dynamic> s, int v) async {
    final next = s['my_vote'] == v ? 0 : v;
    try {
      await MusicApi.vote(s['id'] as String, next);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    _load(quiet: true);
  }

  Future<void> _suggest() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SearchSheet(left: _left),
    );
    if (added == true) _load();
  }

  Future<void> _staff(Map<String, dynamic> s) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(s['title'] as String, style: B.heading(20)), subtitle: Text(s['artist'] as String)),
          if (s['status'] != 'played')
            ListTile(leading: const Icon(Icons.check), title: const Text('Played it'), onTap: () => Navigator.pop(ctx, 'played')),
          if (s['status'] != 'in')
            ListTile(leading: const Icon(Icons.undo), title: const Text('Put it back on the list'), onTap: () => Navigator.pop(ctx, 'in')),
          ListTile(leading: Icon(Icons.close, color: B.urgent), title: const Text('Remove it'), onTap: () => Navigator.pop(ctx, 'removed')),
        ]),
      ),
    );
    if (pick == null) return;
    try {
      await MusicApi.staffSet(s['id'] as String, pick);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
    _load(quiet: true);
  }

  @override
  Widget build(BuildContext context) {
    final playing = _list.where((s) => s['status'] == 'in').toList();
    final done = _list.where((s) => s['status'] != 'in').toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.staff ? 'Tonight\'s requests' : 'Music', style: B.heading(22))),
      floatingActionButton: widget.staff
          ? null
          : FloatingActionButton.extended(
              onPressed: _left > 0 ? _suggest : null,
              backgroundColor: _left > 0 ? B.gold : B.fill,
              foregroundColor: B.onGold,
              icon: const Icon(Icons.add),
              label: Text(_left > 0 ? 'SUGGEST ($_left LEFT)' : 'NO SUGGESTIONS LEFT'),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 100), children: [
          Text(widget.placeName, style: B.display(28)),
          const SizedBox(height: 4),
          Text(
            widget.staff
                ? 'What people checked in here want to hear, best first. You have the final say.'
                : 'Suggest up to 3 tonight and vote the rest up or down. The list resets at closing; the bar has the final say.',
            style: TextStyle(color: B.muted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          if (_loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _list.isEmpty)
            Padding(
              padding: const EdgeInsets.all(30),
              child: Text('Nothing on the list yet. Be the first.', textAlign: TextAlign.center, style: TextStyle(color: B.muted)),
            ),
          for (var i = 0; i < playing.length; i++) _SongCard(song: playing[i], rank: i + 1, staff: widget.staff, onVote: _vote, onStaff: _staff),
          if (done.isNotEmpty) ...[
            const SizedBox(height: 16),
            const SectionLabel('Played or voted off'),
            const SizedBox(height: 8),
            for (final s in done) _SongCard(song: s, staff: widget.staff, onVote: _vote, onStaff: _staff),
          ],
        ]),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover(this.url, {this.size = 56});
  final String? url;
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(B.radius),
        child: SizedBox(
          width: size,
          height: size,
          child: url == null
              ? Container(color: B.fill, child: Icon(Icons.album, color: B.muted))
              : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: B.fill)),
        ),
      );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.kind, required this.id});
  final String kind;
  final int id;
  @override
  Widget build(BuildContext context) {
    final key = '$kind:$id';
    return ValueListenableBuilder<String?>(
      valueListenable: _Player.playing,
      builder: (context, now, _) => IconButton(
        tooltip: now == key ? 'Stop' : 'Play 30 seconds',
        icon: Icon(now == key ? Icons.stop_circle_outlined : Icons.play_circle_outline, color: B.goldInk),
        onPressed: () async {
          try {
            await _Player.toggle(key, () => MusicApi.preview(id, album: kind == 'album'));
          } catch (e) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
          }
        },
      ),
    );
  }
}

class _SongCard extends StatelessWidget {
  const _SongCard({required this.song, required this.staff, required this.onVote, required this.onStaff, this.rank});
  final Map<String, dynamic> song;
  final int? rank;
  final bool staff;
  final Future<void> Function(Map<String, dynamic>, int) onVote;
  final Future<void> Function(Map<String, dynamic>) onStaff;

  @override
  Widget build(BuildContext context) {
    final s = song;
    final mine = s['my_vote'] as int? ?? 0;
    final open = s['status'] == 'in';
    final who = (s['suggested_by'] as String?)?.isNotEmpty == true ? s['suggested_by'] as String : 'Someone';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: B.cardBox(),
        child: Row(children: [
          if (rank != null)
            SizedBox(width: 24, child: Text('$rank', style: B.heading(18).copyWith(color: B.goldInk))),
          _Cover(s['cover'] as String?),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${s['artist']}${s['kind'] == 'album' ? ' · album' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: B.muted, fontSize: 12.5)),
              Text(
                switch (s['status']) {
                  'played' => 'Played · added by ${s['mine'] == true ? 'you' : who}',
                  'out' => 'Voted off',
                  _ => 'Added by ${s['mine'] == true ? 'you' : who} · ${s['ups']} up, ${s['downs']} down',
                },
                style: TextStyle(color: B.muted, fontSize: 11.5),
              ),
            ]),
          ),
          _PlayButton(kind: s['kind'] as String, id: (s['deezer_id'] as num).toInt()),
          if (staff)
            IconButton(tooltip: 'Final say', icon: const Icon(Icons.more_vert), onPressed: () => onStaff(s))
          else if (open)
            Column(mainAxisSize: MainAxisSize.min, children: [
              InkWell(
                onTap: () => onVote(s, 1),
                child: Icon(Icons.keyboard_arrow_up, size: 28, color: mine == 1 ? B.accent : B.muted),
              ),
              Text('${s['net']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              InkWell(
                onTap: () => onVote(s, -1),
                child: Icon(Icons.keyboard_arrow_down, size: 28, color: mine == -1 ? B.urgent : B.muted),
              ),
            ]),
        ]),
      ),
    );
  }
}

/// Search Deezer and suggest a song or album.
class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.left});
  final int left;
  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _q = TextEditingController();
  bool _albums = false;
  List<Map<String, dynamic>> _hits = [];
  bool _busy = false;
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _search() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final r = await MusicApi.search(_q.text, albums: _albums);
        if (mounted) setState(() {
          _hits = r;
          _error = null;
        });
      } catch (e) {
        if (mounted) setState(() => _error = _clean(e));
      }
    });
  }

  Future<void> _add(Map<String, dynamic> h) async {
    setState(() => _busy = true);
    try {
      final r = await MusicApi.suggest(h);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['already'] == true ? 'Already on the list: your vote went to it.' : 'Added to tonight\'s list.')));
      Navigator.pop(context, true);
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
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Suggest something', style: B.heading(24)),
            const SizedBox(height: 4),
            Text('${widget.left} left tonight. Tap play to hear 30 seconds first.', style: TextStyle(color: B.muted, fontSize: 13)),
            const SizedBox(height: 10),
            Row(children: [
              PillChip(label: 'Songs', selected: !_albums, onTap: () => setState(() { _albums = false; _search(); })),
              const SizedBox(width: 6),
              PillChip(label: 'Albums', selected: _albums, onTap: () => setState(() { _albums = true; _search(); })),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _q,
              autofocus: true,
              onChanged: (_) => _search(),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Song, album or artist'),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: B.urgent))),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final h in _hits)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _Cover(h['cover'] as String?, size: 44),
                    title: Text(h['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(h['artist'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      _PlayButton(kind: h['kind'] as String, id: (h['id'] as num).toInt()),
                      IconButton(
                        tooltip: 'Suggest',
                        icon: Icon(Icons.add_circle, color: B.gold),
                        onPressed: _busy ? null : () => _add(h),
                      ),
                    ]),
                  ),
              ]),
            ),
          ]),
        ),
      );
}
