import 'package:flutter/material.dart';

import '../theme.dart';

/// One tab on the left rail.
class RailItem {
  const RailItem(this.label, this.icon, this.activeIcon, {this.badge = false});
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool badge; // small blue dot (e.g. a reply is waiting)
}

/// The navigation rail down the left side: every destination in one place.
/// Dating tabs first, then (for testers) a thin divider and the other Based Social modules.
class ModuleRail extends StatelessWidget {
  const ModuleRail({super.key, required this.items, required this.index, required this.onTap, this.dividerAfter});
  final List<RailItem> items;
  final int index;
  final ValueChanged<int> onTap;

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
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: B.isDark ? B.line : Colors.transparent, width: 0.8),
          boxShadow: B.shadow,
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 10),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: 'B', style: B.display(26).copyWith(color: Colors.white)),
              TextSpan(text: '.', style: B.display(26).copyWith(color: B.accent)),
            ])),
          ),
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
          borderRadius: BorderRadius.circular(10),
          onTap: () => onTap(i),
          child: Container(
            height: 58,
            decoration: on ? BoxDecoration(color: B.panelRaised, borderRadius: BorderRadius.circular(10)) : null,
            child: Stack(alignment: Alignment.center, children: [
              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(on ? m.activeIcon : m.icon, size: 22, color: on ? Colors.white : B.onPanelMuted),
                const SizedBox(height: 4),
                Text(m.label,
                    style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.2,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                        color: on ? Colors.white : B.onPanelMuted)),
              ]),
              if (m.badge && !on)
                Positioned(top: 9, right: 14, child: CircleAvatar(radius: 4, backgroundColor: B.accent)),
              if (on)
                Positioned(
                  left: 0,
                  top: 16,
                  bottom: 16,
                  child: Container(width: 3, decoration: BoxDecoration(color: B.accent, borderRadius: BorderRadius.circular(2))),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
