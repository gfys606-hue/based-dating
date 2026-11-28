import 'package:flutter/material.dart';

import '../theme.dart';

/// One tab on the left rail.
class RailItem {
  const RailItem(this.label, this.icon, this.activeIcon, {this.badge = false, this.brandMark = false});
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool badge; // small blue dot (e.g. a reply is waiting)

  /// Home: show the "B" mark instead of an icon + label. It doubles as the rail's
  /// brand stamp, so the rail no longer needs a separate non-interactive header above it.
  final bool brandMark;
}

/// The navigation rail down the left side: every destination in one place.
/// Dating tabs first, then (for testers) a thin divider and the other Based Social modules.
class ModuleRail extends StatelessWidget {
  const ModuleRail(
      {super.key, required this.items, required this.index, required this.onTap, this.dividerAfter, this.footer = const []});
  final List<RailItem> items;
  final int index;
  final ValueChanged<int> onTap;

  /// Small buttons pinned to the bottom of the rail (e.g. testers' suggestion / report buttons),
  /// kept here so nothing floats over the page and hides its last line or button.
  final List<Widget> footer;

  /// Draw a divider after this item index (separates dating from the other modules).
  final int? dividerAfter;

  static const width = 68.0;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      right: false,
      minimum: const EdgeInsets.fromLTRB(8, 10, 0, 10),
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: B.panel,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: B.isDark ? B.line : Colors.transparent, width: 0.8),
          boxShadow: B.shadow,
        ),
        child: Column(children: [
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(children: [
                for (var i = 0; i < items.length; i++) ...[
                  _item(i),
                  if (dividerAfter == i)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Container(height: 1, color: B.onPanelMuted.withOpacity(.35)),
                    ),
                ],
              ]),
            ),
          ),
          if (footer.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(height: 1, color: B.onPanelMuted.withOpacity(.35)),
            ),
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: footer)),
          ],
        ]),
      ),
    );
  }

  Widget _item(int i) {
    final m = items[i];
    final on = i == index;
    return Semantics(
      selected: on,
      button: true,
      label: m.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => onTap(i),
          child: Container(
            height: 58,
            decoration: on ? BoxDecoration(color: B.panelRaised, borderRadius: BorderRadius.circular(4)) : null,
            child: Stack(alignment: Alignment.center, children: [
              if (m.brandMark)
                // The logo itself, in its true metal color — it's the brand, not a status icon,
                // so it doesn't get tinted or greyed out when the tab isn't the active one.
                Image.asset('assets/icon/mark.png', width: 30, height: 30)
              else
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(on ? m.activeIcon : m.icon, size: 22, color: on ? Colors.white : B.onPanelMuted),
                  const SizedBox(height: 4),
                  Text(m.label.toUpperCase(),
                      style: TextStyle(
                          fontSize: 9.5,
                          letterSpacing: 1.0,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                          color: on ? Colors.white : B.onPanelMuted)),
                ]),
              if (m.badge && !on)
                Positioned(top: 9, right: 14, child: CircleAvatar(radius: 4, backgroundColor: B.gold)),
              if (on)
                Positioned(
                  left: 0,
                  top: 16,
                  bottom: 16,
                  child: Container(width: 3, decoration: BoxDecoration(color: B.gold, borderRadius: BorderRadius.circular(2))),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
