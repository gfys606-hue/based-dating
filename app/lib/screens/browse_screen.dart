import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/rooms_api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

String _clean(Object e) {
  final s = e.toString();
  final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
  return (m?.group(1) ?? s.replaceFirst(RegExp(r'^.*?(Exception|Error): ?'), '')).trim();
}

/// Browse: look around your city yourself. Two-way: only people who also have Browse on show up,
/// and with yours off nobody can find you here. "Ouch" shows only people who have dating on.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});
  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  bool? _on;
  bool _dating = false;
  List<Map<String, dynamic>> _people = [];
  bool _loading = false;
  String? _error;
  final Set<String> _liked = {};

  @override
  void initState() {
    super.initState();
    Api.myProfile().then((p) {
      if (!mounted) return;
      setState(() => _on = p?['browse_on'] == true);
      if (_on == true) _load();
    }).catchError((_) {});
  }

  Future<void> _setOn(bool v) async {
    setState(() => _on = v);
    try {
      await Api.updateProfile({'browse_on': v});
      if (v) {
        _load();
      } else {
        setState(() => _people = []);
      }
    } catch (_) {
      if (mounted) setState(() => _on = !v);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await RoomsApi.browse(dating: _dating);
      if (mounted) setState(() => _people = r);
    } catch (e) {
      if (mounted) setState(() {
        _people = [];
        _error = _clean(e);
      });
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _like(Map<String, dynamic> p) async {
    final id = p['user_id'] as String;
    try {
      final match = await Api.like(id);
      setState(() => _liked.add(id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(match != null ? 'It\'s a match with ${p['name']}. Say hi in Talk.' : 'Liked. If they like you back, it\'s a match.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_clean(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _on;
    return Scaffold(
      appBar: AppBar(title: Text('Browse', style: B.heading(22))),
      body: on == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 40), children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: on,
                  title: const Text('Browse'),
                  subtitle: Text(on
                      ? 'On: you can look around, and people browsing can find you.'
                      : 'Off: you can\'t browse, and nobody can find you here.'),
                  onChanged: _setOn,
                ),
                if (on) ...[
                  Row(children: [
                    PillChip(label: 'Everyone', selected: !_dating, onTap: () { setState(() => _dating = false); _load(); }),
                    const SizedBox(width: 6),
                    PillChip(label: 'Ouch', selected: _dating, onTap: () { setState(() => _dating = true); _load(); }),
                  ]),
                  const SizedBox(height: 12),
                  if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
                  if (_error != null) Text(_error!, style: TextStyle(color: B.urgent)),
                  if (!_loading && _error == null && _people.isEmpty)
                    Text('No one else has Browse on yet.', style: TextStyle(color: B.muted)),
                  for (final p in _people)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ProfileViewScreen(userId: p['user_id'] as String),
                        )),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: B.cardBox(),
                          child: Row(children: [
                            Avatar(path: p['photo'] as String?, size: 52),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${p['name']}, ${p['age']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                Text(
                                  [
                                    if (p['distance_km'] != null) '${p['distance_km']} km',
                                    (p['shared'] as List).isEmpty ? 'different interests' : 'both into ${(p['shared'] as List).take(3).join(', ')}',
                                  ].join(' · '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: B.muted, fontSize: 12.5),
                                ),
                              ]),
                            ),
                            if (_dating)
                              IconButton(
                                tooltip: 'Like',
                                icon: Icon(_liked.contains(p['user_id']) ? Icons.favorite : Icons.favorite_border, color: B.accent),
                                onPressed: _liked.contains(p['user_id']) ? null : () => _like(p),
                              ),
                          ]),
                        ),
                      ),
                    ),
                ],
              ]),
            ),
    );
  }
}
