import 'package:flutter/material.dart';

import '../services/diagnostics.dart';
import '../widgets/feedback_sheet.dart';

import '../services/api.dart';
import '../services/friends_api.dart';
import '../services/places_api.dart';
import '../theme.dart';
import '../widgets/module_rail.dart';
import 'discover_screen.dart';
import 'friends_screen.dart';
import 'home_screen.dart';
import 'spots_screen.dart';
import 'talk_screen.dart';
import 'you_screen.dart';

/// An extra module page on the rail (testers: Circles, Search, Events, Market).
/// [build] gets `open(module)` so a page can jump to another module (1 Circles, 2 Search, 3 Events, 4 Market).
class ShellPage {
  const ShellPage(this.item, this.build);
  final RailItem item;
  final Widget Function(void Function(int module) open) build;
}

/// The app shell: every destination lives on the left rail (no bottom bar).
/// Home (Your day) · Discover · Talk · You · Friends · Spots, then any extra modules.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.onStatusChanged, this.extras = const []});
  final VoidCallback onStatusChanged;
  final List<ShellPage> extras;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  bool _talkBadge = false;
  bool _friendsBadge = false;
  final _opened = <int>{0, 1, 2, 3, 4, 5}; // extra modules are built the first time they're opened

  /// Which view Discover shows: 0 = people, 1 = posts. Home can switch it.
  final discoverMode = ValueNotifier<int>(0);

  // Bumped to make a tab reload its data when you switch to it.
  final _refresh = [ValueNotifier<int>(0), ValueNotifier<int>(0), ValueNotifier<int>(0), ValueNotifier<int>(0), ValueNotifier<int>(0), ValueNotifier<int>(0)];

  @override
  void initState() {
    super.initState();
    _checkBadge();
    PlacesApi.refreshMyLocation(); // distances use where you are now, not where you signed up
  }

  Future<void> _checkBadge() async {
    try {
      final ms = await Api.myMatches();
      final waiting = ms.any((m) => m['last_message'] != null && m['last_from_me'] == false);
      if (mounted) setState(() => _talkBadge = waiting);
    } catch (_) {}
    try {
      final req = await FriendsApi.requests();
      final fr = await FriendsApi.friends();
      final unread = fr.any((f) => f['last_message'] != null && f['last_from_me'] == false);
      if (mounted) setState(() => _friendsBadge = req.isNotEmpty || unread);
    } catch (_) {}
  }

  void goTab(int i, {int? discover}) {
    if (discover != null) discoverMode.value = discover;
    setState(() {
      _tab = i;
      _opened.add(i);
    });
    if (i < _refresh.length) _refresh[i].value++;
    _checkBadge();
  }

  /// Extra module 1..n → rail index 6..
  void _openModule(int module) => goTab(5 + module);

  @override
  Widget build(BuildContext context) {
    final items = [
      const RailItem('Home', Icons.home_outlined, Icons.home_rounded),
      const RailItem('Discover', Icons.radar_outlined, Icons.radar),
      RailItem('Talk', Icons.chat_bubble_outline, Icons.chat_bubble, badge: _talkBadge),
      const RailItem('You', Icons.person_outline, Icons.person),
      RailItem('Friends', Icons.people_outline, Icons.people, badge: _friendsBadge),
      const RailItem('Spots', Icons.place_outlined, Icons.place),
      for (final e in widget.extras) e.item,
    ];
    Diagnostics.tab = items[_tab.clamp(0, items.length - 1)].label;
    return Scaffold(
      // testers get a "Report a problem" button everywhere
      floatingActionButton: widget.extras.isEmpty
          ? null
          : FloatingActionButton.small(
              heroTag: 'feedback',
              tooltip: 'Report a problem',
              backgroundColor: B.panel,
              foregroundColor: B.gold,
              onPressed: () => showFeedbackSheet(context),
              child: const Icon(Icons.bug_report_outlined, size: 20),
            ),
      body: Row(children: [
        ModuleRail(items: items, index: _tab, onTap: (i) => goTab(i), dividerAfter: widget.extras.isEmpty ? null : 5),
        Expanded(
          child: SafeArea(
            left: false,
            child: IndexedStack(index: _tab, children: [
              HomeScreen(refresh: _refresh[0], goTab: goTab),
              DiscoverScreen(refresh: _refresh[1], mode: discoverMode),
              TalkScreen(refresh: _refresh[2], onChanged: _checkBadge),
              YouScreen(onStatusChanged: widget.onStatusChanged),
              FriendsScreen(refresh: _refresh[4], onChanged: _checkBadge),
              SpotsScreen(refresh: _refresh[5]),
              for (var i = 0; i < widget.extras.length; i++)
                _opened.contains(6 + i) ? widget.extras[i].build(_openModule) : const SizedBox.shrink(),
            ]),
          ),
        ),
      ]),
    );
  }
}
