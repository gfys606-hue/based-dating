import 'package:flutter/material.dart';

import '../services/api.dart';
import '../widgets/nav_bar.dart';
import 'discover_screen.dart';
import 'home_screen.dart';
import 'talk_screen.dart';
import 'you_screen.dart';

/// The app shell: 4 fixed destinations + the floating menu.
/// Home (Your day) · Discover · Talk · You
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.onStatusChanged});
  final VoidCallback onStatusChanged;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  bool _talkBadge = false;

  /// Which view Discover shows: 0 = people, 1 = posts. Home can switch it.
  final discoverMode = ValueNotifier<int>(0);

  // Bumped to make a tab reload its data when you switch to it.
  final _refresh = [ValueNotifier<int>(0), ValueNotifier<int>(0), ValueNotifier<int>(0), ValueNotifier<int>(0)];

  @override
  void initState() {
    super.initState();
    _checkBadge();
  }

  Future<void> _checkBadge() async {
    try {
      final ms = await Api.myMatches();
      final waiting = ms.any((m) => m['last_message'] != null && m['last_from_me'] == false);
      if (mounted) setState(() => _talkBadge = waiting);
    } catch (_) {}
  }

  void goTab(int i, {int? discover}) {
    if (discover != null) discoverMode.value = discover;
    setState(() => _tab = i);
    _refresh[i].value++;
    _checkBadge();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _tab, children: [
          HomeScreen(refresh: _refresh[0], goTab: goTab),
          DiscoverScreen(refresh: _refresh[1], mode: discoverMode),
          TalkScreen(refresh: _refresh[2], onChanged: _checkBadge),
          YouScreen(onStatusChanged: widget.onStatusChanged),
        ]),
      ),
      bottomNavigationBar: BasedNavBar(index: _tab, onTap: (i) => goTab(i), talkBadge: _talkBadge),
    );
  }
}
