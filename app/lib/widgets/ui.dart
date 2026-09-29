import 'package:flutter/material.dart';

import '../theme.dart';
import 'signed_photo.dart';

/// Shared building blocks. Future modules reuse these instead of inventing their own.

/// Hours left in a match's 3-day call window.
double hoursLeft(Map<String, dynamic> m) =>
    DateTime.parse(m['call_deadline'] as String).difference(DateTime.now()).inMinutes / 60.0;

String timeLeftLabel(double h) {
  if (h <= 0) return 'Expiring';
  if (h >= 24) return '${h ~/ 24}d ${(h % 24).floor()}h';
  if (h >= 1) return '${h.floor()}h';
  return '${(h * 60).floor()}m';
}

/// "2d 5h to call" style countdown for a match.
String callCountdown(Map<String, dynamic> m) {
  if (m['call_done'] == true) return m['contact_unlocked'] == true ? 'Numbers unlocked' : 'Call done';
  final h = hoursLeft(m);
  return h <= 0 ? 'Expiring' : '${timeLeftLabel(h)} to call';
}

/// Colour for a deadline: red under 24h, amber under 2 days, ink otherwise.
({Color color, Color track}) urgencyColors(double h) {
  if (h < 24) return (color: B.urgent, track: B.urgentSoft);
  if (h < 48) return (color: B.soon, track: B.soonSoft);
  return (color: B.ink, track: B.line);
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: B.label.copyWith(color: color ?? B.muted));
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, this.path, required this.size, this.square = false});
  final String? path;
  final double size;
  final bool square;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: SignedPhoto(path, radius: square ? size * .3 : size / 2),
      );
}

/// Thin progress bar showing how much of a deadline is left.
class DeadlineBar extends StatelessWidget {
  const DeadlineBar({super.key, required this.fraction, required this.color, required this.track, this.height = 5});
  final double fraction;
  final Color color;
  final Color track;
  final double height;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: LinearProgressIndicator(
          value: fraction.clamp(0.06, 1.0),
          minHeight: height,
          color: color,
          backgroundColor: track,
        ),
      );
}

/// Timer tile: used for "Needs you" on Home and "Needs a call" in Talk.
/// (Later modules reuse it for deliveries, RSVPs, etc.)
class TimerTile extends StatelessWidget {
  const TimerTile({super.key, required this.match, required this.onTap, this.caption});
  final Map<String, dynamic> match;
  final VoidCallback onTap;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final h = hoursLeft(match);
    final u = urgencyColors(h);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(B.radius),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: B.cardBox(border: h < 24 ? B.urgent : null),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Avatar(path: match['other_photo'] as String?, size: 34),
              const SizedBox(width: 8),
              Expanded(
                child: Text(match['other_name'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15), overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 8),
            Text(caption ?? (match['next_call_status'] == 'accepted' ? 'Call booked' : 'No call booked yet'),
                style: TextStyle(fontSize: 13, color: B.ink2)),
            const SizedBox(height: 6),
            Text(timeLeftLabel(h), style: B.display(20).copyWith(color: u.color)),
            const SizedBox(height: 6),
            DeadlineBar(fraction: h / 72, color: u.color, track: u.track),
          ]),
        ),
      ),
    );
  }
}

/// Pill chip used for filters (People/Posts, distance ranges, interests).
class PillChip extends StatelessWidget {
  const PillChip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? B.panel : B.card,
          shape: StadiumBorder(side: BorderSide(color: selected ? B.panel : B.line, width: 1.5)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              child: Text(label,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: selected ? Colors.white : B.ink)),
            ),
          ),
        ),
      );
}

/// Two-option segmented switch (Cards / Radar).
class Segmented extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.index, required this.onChanged});
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: Container(
                constraints: const BoxConstraints(minHeight: 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: i == index
                    ? BoxDecoration(color: B.isDark ? B.panelRaised : B.card, borderRadius: BorderRadius.circular(9), boxShadow: B.shadow)
                    : null,
                child: Text(options[i],
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: i == index ? FontWeight.w700 : FontWeight.w600,
                        color: i == index ? B.ink : B.muted)),
              ),
            ),
        ]),
      );
}
