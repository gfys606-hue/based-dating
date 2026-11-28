import 'package:flutter/material.dart';

import '../theme.dart';

/// The app's background and page-transition system.
///
/// This used to paint a different room photo (assets/rooms) behind every tab, with a stone
/// staircase you "walked down" between pages. That's gone now in favor of a plain, modern flat
/// background — cleaner, lighter to render, and it doesn't fight with real content on screen.
/// [Castle.view] and [Castle.load] stay as a no-op API so the rest of the app (which sets the
/// current tab on every navigation) doesn't need to change.
class Castle {
  Castle._();

  /// Kept for compatibility with call sites that record the current tab; no longer drives
  /// a background image.
  static final view = ValueNotifier<int>(0);

  static const landing = 100;

  /// No photos to load anymore; kept so main.dart's startup sequence doesn't need to change.
  static Future<void> load() async {}
}

/// The app's background: a single flat fill, the same color as the page itself.
class CastleBackdrop extends StatelessWidget {
  const CastleBackdrop({super.key, this.fixed});
  final int? fixed;

  @override
  Widget build(BuildContext context) => ColoredBox(color: B.bg);
}

/// A simple, modern page transition: fade + a short upward drift. Replaces the old stone
/// staircase effect.
class StairsTransitions extends PageTransitionsBuilder {
  const StairsTransitions();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: curved.drive(Tween(begin: const Offset(0, 0.03), end: Offset.zero)),
        child: child,
      ),
    );
  }
}
