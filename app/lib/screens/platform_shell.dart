import 'package:flutter/material.dart';

import '../widgets/module_rail.dart';
import 'circles_screen.dart';
import 'events_screen.dart';
import 'home_shell.dart';
import 'market_screen.dart';
import 'search_screen.dart';

/// Based Social: module tabs down the left side, the chosen module on the right.
/// Shown to testers only; everyone else gets the dating app on its own.
class PlatformShell extends StatefulWidget {
  const PlatformShell({super.key, required this.onStatusChanged});
  final VoidCallback onStatusChanged;
  @override
  State<PlatformShell> createState() => _PlatformShellState();
}

class _PlatformShellState extends State<PlatformShell> {
  int _module = 0;
  final _opened = <int>{0}; // build a module the first time it's opened, then keep it alive

  Widget _build(int i) {
    if (!_opened.contains(i)) return const SizedBox.shrink();
    switch (i) {
      case 1:
        return const CirclesScreen();
      case 2:
        return SearchScreen(openModule: _open);
      case 3:
        return const EventsScreen();
      case 4:
        return const MarketScreen();
      default:
        return HomeShell(onStatusChanged: widget.onStatusChanged);
    }
  }

  void _open(int i) => setState(() {
        _module = i;
        _opened.add(i);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(children: [
        ModuleRail(index: _module, onTap: _open),
        Expanded(
          child: IndexedStack(index: _module, children: [
            for (var i = 0; i < basedModules.length; i++) _build(i),
          ]),
        ),
      ]),
    );
  }
}
