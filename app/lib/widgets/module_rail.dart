import 'package:flutter/material.dart';

import '../theme.dart';

/// A Based Social module shown as a tab on the left rail.
class BasedModule {
  const BasedModule(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

const basedModules = [
  BasedModule('Dating', Icons.favorite_border, Icons.favorite),
  BasedModule('Circles', Icons.bubble_chart_outlined, Icons.bubble_chart),
  BasedModule('Search', Icons.search, Icons.search),
  BasedModule('Events', Icons.event_outlined, Icons.event),
  BasedModule('Market', Icons.storefront_outlined, Icons.storefront),
];

/// The dark floating rail down the left side: one tab per module.
/// Same look as the bottom menu so the whole platform feels like one app.
class ModuleRail extends StatelessWidget {
  const ModuleRail({super.key, required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const width = 64.0;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      right: false,
      minimum: const EdgeInsets.fromLTRB(8, 10, 0, 14),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: B.ink,
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [BoxShadow(color: Color(0x5515181D), blurRadius: 24, spreadRadius: -10, offset: Offset(4, 8))],
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 10),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: 'B', style: B.display(24).copyWith(color: Colors.white)),
              TextSpan(text: '.', style: B.display(24).copyWith(color: B.accent)),
            ])),
          ),
          for (var i = 0; i < basedModules.length; i++) _item(i),
          const Spacer(),
        ]),
      ),
    );
  }

  Widget _item(int i) {
    final m = basedModules[i];
    final on = i == index;
    return Semantics(
      selected: on,
      button: true,
      label: m.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => onTap(i),
          child: Container(
            height: 60,
            decoration: on ? BoxDecoration(color: const Color(0xFF2A2F36), borderRadius: BorderRadius.circular(16)) : null,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(on ? m.activeIcon : m.icon, size: 22, color: on ? Colors.white : const Color(0xFF9BA0A7)),
              const SizedBox(height: 4),
              Text(m.label,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                      color: on ? Colors.white : const Color(0xFF9BA0A7))),
            ]),
          ),
        ),
      ),
    );
  }
}
