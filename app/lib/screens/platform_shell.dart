import 'package:flutter/material.dart';

import '../widgets/module_rail.dart';
import 'circles_screen.dart';
import 'events_screen.dart';
import 'home_shell.dart';
import 'market_screen.dart';
import 'search_screen.dart';

/// Based Social (testers only): the dating tabs plus the other modules, all on one left rail.
/// Everyone else gets the dating app on its own (HomeShell with no extras).
class PlatformShell extends StatelessWidget {
  const PlatformShell({super.key, required this.onStatusChanged});
  final VoidCallback onStatusChanged;

  @override
  Widget build(BuildContext context) {
    return HomeShell(
      onStatusChanged: onStatusChanged,
      extras: [
        ShellPage(const RailItem('Herd', Icons.groups_outlined, Icons.groups), (_) => const CirclesScreen()),
        ShellPage(const RailItem('Search', Icons.search, Icons.search), (open) => SearchScreen(openModule: open)),
        ShellPage(const RailItem('Events', Icons.event_outlined, Icons.event), (_) => const EventsScreen()),
        ShellPage(const RailItem('Market', Icons.storefront_outlined, Icons.storefront), (_) => const MarketScreen()),
      ],
    );
  }
}
