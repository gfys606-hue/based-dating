import 'package:flutter/material.dart';

import '../widgets/module_rail.dart';
import 'circles_screen.dart';
import 'events_screen.dart';
import 'home_shell.dart';
import 'ideas_screen.dart';
import 'market_screen.dart';
import 'search_screen.dart';

/// The whole app, for every member: the dating tabs plus Ideas, Herd, Search, Events and Market on one left rail.
class PlatformShell extends StatelessWidget {
  const PlatformShell({super.key, required this.onStatusChanged});
  final VoidCallback onStatusChanged;

  @override
  Widget build(BuildContext context) {
    return HomeShell(
      onStatusChanged: onStatusChanged,
      extras: [
        ShellPage(const RailItem('Ideas', Icons.lightbulb_outline, Icons.lightbulb), (_) => const IdeasScreen()),
        ShellPage(const RailItem('Herd', Icons.groups_outlined, Icons.groups), (_) => const CirclesScreen()),
        ShellPage(const RailItem('Search', Icons.search, Icons.search), (open) => SearchScreen(openModule: open)),
        ShellPage(const RailItem('Events', Icons.event_outlined, Icons.event), (_) => const EventsScreen()),
        ShellPage(const RailItem('Market', Icons.storefront_outlined, Icons.storefront), (_) => const MarketScreen()),
      ],
    );
  }
}
