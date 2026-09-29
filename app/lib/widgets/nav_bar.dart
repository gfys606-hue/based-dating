import 'package:flutter/material.dart';

import '../theme.dart';

/// The floating dark menu. These 4 slots never change as modules are added:
/// new modules show up inside them (Discover becomes the search for everything).
class BasedNavBar extends StatelessWidget {
  const BasedNavBar({super.key, required this.index, required this.onTap, this.talkBadge = false});
  final int index;
  final ValueChanged<int> onTap;
  final bool talkBadge;

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.radar_outlined, Icons.radar, 'Discover'),
    (Icons.chat_bubble_outline, Icons.chat_bubble, 'Talk'),
    (Icons.person_outline, Icons.person, 'You'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Container(
        height: B.navHeight,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: B.panel,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: const Color(0xFF15181D).withOpacity(.45), blurRadius: 30, spreadRadius: -10, offset: const Offset(0, 12))],
        ),
        child: Row(children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: Semantics(
                selected: i == index,
                button: true,
                label: _items[i].$3,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => onTap(i),
                  child: Container(
                    height: 56,
                    decoration: i == index
                        ? BoxDecoration(color: B.panelRaised, borderRadius: BorderRadius.circular(18))
                        : null,
                    child: Stack(alignment: Alignment.center, children: [
                      Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(i == index ? _items[i].$2 : _items[i].$1,
                            size: 22, color: i == index ? Colors.white : B.onPanelMuted),
                        const SizedBox(height: 3),
                        Text(_items[i].$3,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: i == index ? FontWeight.w700 : FontWeight.w600,
                                color: i == index ? Colors.white : B.onPanelMuted)),
                      ]),
                      if (i == 2 && talkBadge && i != index)
                        const Positioned(
                          top: 10,
                          right: 22,
                          child: CircleAvatar(radius: 4, backgroundColor: Color(0xFF5B7FEA)),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
