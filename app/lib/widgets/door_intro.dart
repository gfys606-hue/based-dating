import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';

/// The opening (about 8.5 seconds, tap to skip):
///   black → a bulb flickers on over a long dark hallway → you drift toward a door with light under it
///   → "The Door" → a shadow passes behind it → the door cracks open, holds… → swings open onto a
///   stairwell going down → "is not for everyone." → you walk through and down into the app.
/// Plays once each time the app is opened.
class DoorIntro extends StatefulWidget {
  const DoorIntro({super.key, required this.child});
  final Widget child;

  static bool _played = false; // once per launch (survives light/dark rebuilds)

  @override
  State<DoorIntro> createState() => _DoorIntroState();
}

class _DoorIntroState extends State<DoorIntro> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 8500));
  bool _show = !DoorIntro._played;
  bool _fading = false;

  @override
  void initState() {
    super.initState();
    if (!_show) return;
    DoorIntro._played = true;
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // People who turned off animations on their phone go straight in
      if (MediaQuery.of(context).disableAnimations) {
        _finish();
      } else {
        _c.forward();
      }
    });
  }

  void _finish() {
    if (_fading || !mounted) return;
    setState(() => _fading = true);
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _show = false);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return widget.child;
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      AnimatedOpacity(
        opacity: _fading ? 0 : 1,
        duration: const Duration(milliseconds: 500),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _finish,
          child: AnimatedBuilder(animation: _c, builder: (context, _) => _scene(context, _c.value)),
        ),
      ),
    ]);
  }

  static double _seg(double t, double a, double b, [Curve curve = Curves.linear]) =>
      curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  /// The bulb catching: off, a couple of stutters, then on with a faint hum. Dips once when the door cracks.
  static double _bulb(double t) {
    if (t < 0.030) return 0;
    if (t < 0.042) return 0.85;
    if (t < 0.056) return 0.10;
    if (t < 0.064) return 0.70;
    if (t < 0.074) return 0.25;
    final hum = 0.94 + 0.06 * math.sin(t * 260) * math.sin(t * 37);
    final dip = (t > 0.395 && t < 0.415) ? 0.45 : 1.0;
    return math.min(1.0, _seg(t, 0.074, 0.10)) * hum * dip;
  }

  Widget _scene(BuildContext context, double t) {
    final size = MediaQuery.of(context).size;
    final g = _Geometry(size);

    final fadeIn = _seg(t, 0.0, 0.10, Curves.easeOut);
    final bulb = _bulb(t);
    // The door: cracks open a few degrees, holds, then swings
    final open = t < 0.52 ? 0.07 * _seg(t, 0.38, 0.44, Curves.easeOut) : 0.07 + 0.93 * _seg(t, 0.52, 0.68, Curves.easeInOutCubic);
    final under = 0.45 + 0.45 * math.sin(_seg(t, 0.28, 0.37) * math.pi); // light under the door swells…
    final shadowPass = _seg(t, 0.28, 0.37, Curves.easeInOut); // …as someone crosses behind it
    final word1 = _seg(t, 0.14, 0.26, Curves.easeOut);
    final word2 = _seg(t, 0.62, 0.74, Curves.easeOut);
    final dolly = 1 + 0.28 * _seg(t, 0.0, 0.62, Curves.easeInOut); // a slow walk toward the door
    final walk = _seg(t, 0.80, 0.99, Curves.easeInCubic); // through the doorway and down
    final textOut = 1 - _seg(t, 0.80, 0.86);
    final black = _seg(t, 0.92, 1.0);

    final zoom = dolly * (1 + walk * 11);
    final focus = Offset.lerp(g.doorCenter, g.stairFocus, walk)!;

    final serif = GoogleFonts.cormorantGaramond(color: B.gold, fontWeight: FontWeight.w700, height: 1.0);
    final big = math.min(72.0, size.width * 0.16);

    return Material(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        Opacity(
          opacity: fadeIn,
          child: Transform(
            alignment: Alignment.topLeft,
            transform: Matrix4.identity()
              ..translate(focus.dx, focus.dy)
              ..scale(zoom, zoom)
              ..translate(-focus.dx, -focus.dy),
            child: CustomPaint(
              painter: _HallwayPainter(g, open: open, bulb: bulb, under: under, shadowPass: shadowPass, t: t),
            ),
          ),
        ),
        // Film grain and a heavy vignette, outside the camera move
        IgnorePointer(child: CustomPaint(painter: _GrainPainter(frame: (t * 600).floor()))),
        // The words
        Positioned(
          left: 20,
          right: 20,
          top: g.textTop,
          child: Opacity(
            opacity: textOut,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Opacity(
                opacity: word1,
                child: Transform.translate(
                  offset: Offset(0, 14 * (1 - word1)),
                  child: Text('The Door',
                      textAlign: TextAlign.center,
                      style: serif.copyWith(fontSize: big, letterSpacing: 2, shadows: [
                        Shadow(color: const Color(0xFFFFB347).withOpacity(.55 * word1 * bulb), blurRadius: 30),
                        const Shadow(color: Colors.black, blurRadius: 6, offset: Offset(0, 2)),
                      ])),
                ),
              ),
              const SizedBox(height: 12),
              Opacity(
                opacity: word2,
                child: Transform.translate(
                  offset: Offset(0, 10 * (1 - word2)),
                  child: Text('is not for everyone.',
                      textAlign: TextAlign.center,
                      style: serif.copyWith(
                          fontSize: big * 0.5,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFEDE3C8),
                          shadows: const [Shadow(color: Colors.black, blurRadius: 8, offset: Offset(0, 2))])),
                ),
              ),
            ]),
          ),
        ),
        if (black > 0) ColoredBox(color: Colors.black.withOpacity(black)),
        Positioned(
          bottom: 26 + MediaQuery.of(context).padding.bottom,
          left: 0,
          right: 0,
          child: Opacity(
            opacity: 0.30 * fadeIn * textOut,
            child: Text('tap to enter',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(color: Colors.white, fontSize: 11, letterSpacing: 3, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}

/// Where everything sits, from the screen size. Shared by the painter and the camera.
class _Geometry {
  _Geometry(this.size) {
    final w = size.width, h = size.height;
    final bw = math.min(w * 0.56, h * 0.31); // back wall of the hallway (big: the door is the subject)
    final bh = bw * 1.62;
    final cx = w / 2, cy = h * 0.385;
    back = Rect.fromCenter(center: Offset(cx, cy), width: bw, height: bh);
    final dw = bw * 0.52, dh = bh * 0.80;
    door = Rect.fromLTWH(cx - dw / 2, back.bottom - dh, dw, dh);
    textTop = math.min(h * 0.74, back.bottom + (h - back.bottom) * 0.40);
    stairVp = Offset(door.center.dx, door.top + door.height * 0.64);
    stairHorizon = Offset(door.center.dx, door.top + door.height * 0.40);
  }
  final Size size;
  late final Rect back;
  late final Rect door;
  late final double textTop;
  late final Offset stairVp; // where the stairs vanish (below eye level: they go down)
  late final Offset stairHorizon; // eye level, where flat surfaces vanish
  Offset get doorCenter => door.center;
  Offset get stairFocus => Offset(door.center.dx, door.top + door.height * 0.60);
}

class _HallwayPainter extends CustomPainter {
  _HallwayPainter(this.g, {required this.open, required this.bulb, required this.under, required this.shadowPass, required this.t});
  final _Geometry g;
  final double open; // 0 closed .. 1 open
  final double bulb; // 0 off .. 1 on
  final double under; // light under the door
  final double shadowPass; // 0..1 someone crossing behind the door
  final double t;

  static const _gold = Color(0xFFF5C542);
  static const _warm = Color(0xFFFFAE52);
  static const _wallNear = Color(0xFF07080D);
  static const _wallFar = Color(0xFF191A22);

  static Path _quad(Offset a, Offset b, Offset c, Offset d) =>
      Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy)..lineTo(c.dx, c.dy)..lineTo(d.dx, d.dy)..close();

  /// 0 = at the screen edge, 1 = at the back wall, spaced like real depth
  static double _depth(double s) {
    const k = 3.2;
    return (s * k) / (1 + s * k) * (1 + k) / k;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final b = g.back, d = g.door;
    Offset lerp(Offset a, Offset c, double f) => Offset.lerp(a, c, f)!;

    // ---------- hallway shell ----------
    final ceiling = _quad(Offset.zero, Offset(w, 0), b.topRight, b.topLeft);
    final floor = _quad(Offset(0, h), Offset(w, h), b.bottomRight, b.bottomLeft);
    final left = _quad(Offset.zero, b.topLeft, b.bottomLeft, Offset(0, h));
    final right = _quad(Offset(w, 0), b.topRight, b.bottomRight, Offset(w, h));

    canvas.drawPath(ceiling, Paint()..color = const Color(0xFF040508));
    canvas.drawPath(
        floor,
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, h), Offset(0, b.bottom), const [Color(0xFF050505), Color(0xFF17130F)]));
    for (final isLeft in [true, false]) {
      canvas.drawPath(
          isLeft ? left : right,
          Paint()
            ..shader = ui.Gradient.linear(Offset(isLeft ? 0.0 : w, 0), Offset(isLeft ? b.left : b.right, 0), const [_wallNear, _wallFar]));
    }

    // wallpaper stripes, wainscot, chair rail and baseboard on both side walls
    for (final isLeft in [true, false]) {
      final edgeX = isLeft ? 0.0 : w, backX = isLeft ? b.left : b.right;
      Offset wallPt(double s, double v) {
        // s depth (0 near, 1 back), v height (0 floor, 1 ceiling)
        final f = _depth(s);
        final x = edgeX + (backX - edgeX) * f;
        final top = 0 + (b.top - 0) * f, bot = h + (b.bottom - h) * f;
        return Offset(x, bot + (top - bot) * v);
      }

      final stripe = Paint()
        ..color = const Color(0xFF20212B).withOpacity(.35)
        ..strokeWidth = 1;
      for (var i = 1; i < 26; i++) {
        final s = i / 26;
        canvas.drawLine(wallPt(s, 0.40), wallPt(s, 1.0), stripe);
      }
      final wains = _quad(wallPt(0, 0), wallPt(1, 0), wallPt(1, 0.40), wallPt(0, 0.40));
      canvas.drawPath(wains, Paint()..color = Colors.black.withOpacity(.28));
      for (var i = 1; i < 10; i++) {
        final s = i / 10;
        canvas.drawLine(wallPt(s, 0.06), wallPt(s, 0.36), Paint()..color = const Color(0xFF1C1D26).withOpacity(.5));
      }
      canvas.drawLine(wallPt(0, 0.40), wallPt(1, 0.40), Paint()
        ..color = const Color(0xFF2E2C30).withOpacity(.8)
        ..strokeWidth = 2);
      canvas.drawPath(_quad(wallPt(0, 0), wallPt(1, 0), wallPt(1, 0.055), wallPt(0, 0.055)), Paint()..color = const Color(0xFF0D0C10));
    }

    // floorboards: long seams to the door, staggered cross joints
    final seam = Paint()
      ..color = Colors.black.withOpacity(.55)
      ..strokeWidth = 1;
    const boards = 11;
    for (var i = 1; i < boards; i++) {
      final f = i / boards;
      canvas.drawLine(Offset(w * f, h), Offset(b.left + b.width * f, b.bottom), seam);
    }
    final rnd = math.Random(7);
    for (var i = 0; i < boards; i++) {
      for (var j = 0; j < 6; j++) {
        final s = ((j + rnd.nextDouble()) / 6).clamp(0.02, 0.98);
        final f = _depth(s);
        final y = h + (b.bottom - h) * f;
        final xl = (w * i / boards) + ((b.left + b.width * i / boards) - w * i / boards) * f;
        final xr = (w * (i + 1) / boards) + ((b.left + b.width * (i + 1) / boards) - w * (i + 1) / boards) * f;
        canvas.drawLine(Offset(xl, y), Offset(xr, y), seam);
      }
    }

    // back wall, with its own rail and baseboard either side of the door
    canvas.drawRect(b, Paint()..color = const Color(0xFF181920));
    final railY = b.bottom - b.height * 0.40;
    canvas.drawRect(Rect.fromLTRB(b.left, railY, b.right, b.bottom), Paint()..color = Colors.black.withOpacity(.22));
    canvas.drawLine(Offset(b.left, railY), Offset(b.right, railY), Paint()
      ..color = const Color(0xFF2E2C30)
      ..strokeWidth = 1.6);
    canvas.drawRect(Rect.fromLTRB(b.left, b.bottom - b.height * 0.055, b.right, b.bottom), Paint()..color = const Color(0xFF0D0C10));

    // ---------- the bulb: cord, cone of light, pool on the floor, dust ----------
    final bulbPos = Offset(b.center.dx, b.top + b.height * 0.10);
    final poolC = Offset(b.center.dx, b.bottom + (h - b.bottom) * 0.10);
    canvas.drawLine(Offset(bulbPos.dx, b.top - (b.top) * 0.35), bulbPos - const Offset(0, 4), Paint()
      ..color = const Color(0xFF22201E)
      ..strokeWidth = 1.2);
    if (bulb > 0) {
      // whole-scene warm wash
      canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..shader = ui.Gradient.radial(bulbPos, b.width * 2.6, [_warm.withOpacity(.13 * bulb), _warm.withOpacity(0)]));
      // cone
      final cone = Path()
        ..moveTo(bulbPos.dx - 3, bulbPos.dy)
        ..lineTo(bulbPos.dx + 3, bulbPos.dy)
        ..lineTo(poolC.dx + b.width * 0.95, poolC.dy)
        ..lineTo(poolC.dx - b.width * 0.95, poolC.dy)
        ..close();
      canvas.drawPath(
          cone,
          Paint()
            ..shader = ui.Gradient.linear(bulbPos, poolC, [_warm.withOpacity(.10 * bulb), _warm.withOpacity(.015 * bulb)]));
      // pool on the floor
      canvas.save();
      canvas.translate(poolC.dx, poolC.dy);
      canvas.scale(1, 0.22);
      canvas.drawCircle(
          Offset.zero,
          b.width * 1.05,
          Paint()..shader = ui.Gradient.radial(Offset.zero, b.width * 1.05, [_warm.withOpacity(.16 * bulb), _warm.withOpacity(0)]));
      canvas.restore();
      // dust drifting in the light
      final dust = math.Random(3);
      for (var i = 0; i < 46; i++) {
        final u = dust.nextDouble(), v = dust.nextDouble();
        final y = bulbPos.dy + (poolC.dy - bulbPos.dy) * ((v + t * (0.25 + 0.2 * dust.nextDouble())) % 1.0);
        final spread = (y - bulbPos.dy) / (poolC.dy - bulbPos.dy);
        final x = bulbPos.dx + (u - 0.5) * 2 * b.width * 0.9 * spread + math.sin(t * 9 + i) * 2;
        canvas.drawCircle(Offset(x, y), 0.6 + dust.nextDouble() * 0.8,
            Paint()..color = const Color(0xFFFFE6B8).withOpacity((0.10 + 0.25 * dust.nextDouble()) * bulb * (1 - spread * 0.6)));
      }
      // the bulb itself, with bloom
      canvas.drawCircle(bulbPos, 14, Paint()..shader = ui.Gradient.radial(bulbPos, 14, [const Color(0xFFFFE9C2).withOpacity(.55 * bulb), Colors.transparent]));
      canvas.drawOval(Rect.fromCenter(center: bulbPos, width: 5, height: 7), Paint()..color = const Color(0xFFFFF3D6).withOpacity(bulb));
    } else {
      canvas.drawOval(Rect.fromCenter(center: bulbPos, width: 5, height: 7), Paint()..color = const Color(0xFF2A2724));
    }

    // ---------- the stairwell behind the door ----------
    canvas.save();
    canvas.clipRect(d);
    _stairwell(canvas, d);
    canvas.restore();

    // light from the doorway: under the door, then spilling out as it opens
    final leak = under * (1 - open) + open;
    canvas.save();
    canvas.translate(d.center.dx, d.bottom);
    canvas.scale(1, 0.18);
    canvas.drawCircle(
        Offset.zero,
        d.width * (1.0 + 1.6 * open),
        Paint()..shader = ui.Gradient.radial(Offset.zero, d.width * (1.0 + 1.6 * open), [_warm.withOpacity(.22 * leak), _warm.withOpacity(0)]));
    canvas.restore();
    if (open > 0) {
      final spill = _quad(d.bottomLeft, Offset(d.left + d.width * open, d.bottom),
          Offset(d.center.dx + d.width * (0.5 + 2.2 * open), h), Offset(d.center.dx - d.width * 0.6, h));
      canvas.drawPath(
          spill,
          Paint()..shader = ui.Gradient.linear(d.bottomCenter, Offset(d.center.dx, h), [_warm.withOpacity(.26 * open), _warm.withOpacity(0)]));
      // haze in the doorway
      canvas.drawRect(d, Paint()..color = _warm.withOpacity(.04 * open));
    }

    // ---------- the door, hinged on the left, swinging inward ----------
    final angle = open * 1.38; // ~79°
    final reach = math.cos(angle);
    final depth = 1 / (1 + math.sin(angle) * 0.55);
    final rx = d.left + d.width * reach;
    Offset at(double fx, double fy) {
      final x = d.left + (rx - d.left) * fx;
      final hh = d.height / 2 * (1 + (depth - 1) * fx);
      return Offset(x, d.center.dy - hh + 2 * hh * fy);
    }

    final panel = _quad(at(0, 0), at(1, 0), at(1, 1), at(0, 1));
    final lit = (1 - open * 0.6) * (0.35 + 0.65 * bulb);
    canvas.drawPath(
        panel,
        Paint()
          ..shader = ui.Gradient.linear(d.topCenter, d.bottomCenter, [
            Color.lerp(Colors.black, const Color(0xFF3A2618), lit)!,
            Color.lerp(Colors.black, const Color(0xFF22160E), lit)!,
          ]));
    if (rx - d.left > 2) {
      canvas.save();
      canvas.clipPath(panel);
      // wood grain
      final grain = math.Random(11);
      for (var i = 0; i < 34; i++) {
        final fx = grain.nextDouble();
        final amp = 0.004 + grain.nextDouble() * 0.01;
        final ph = grain.nextDouble() * 6;
        final path = Path();
        for (var k = 0; k <= 24; k++) {
          final fy = k / 24;
          final p = at((fx + amp * math.sin(fy * 9 + ph)).clamp(0.0, 1.0), fy);
          k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = (grain.nextBool() ? Colors.black : const Color(0xFF5A3D26)).withOpacity(.18 * lit));
      }
      // four raised panels with bevels lit from above
      for (final r in const [
        [0.13, 0.07, 0.46, 0.45],
        [0.54, 0.07, 0.87, 0.45],
        [0.13, 0.53, 0.46, 0.93],
        [0.54, 0.53, 0.87, 0.93],
      ]) {
        final p = _quad(at(r[0], r[1]), at(r[2], r[1]), at(r[2], r[3]), at(r[0], r[3]));
        canvas.drawPath(p, Paint()..color = Colors.black.withOpacity(.22));
        canvas.drawLine(at(r[0], r[1]), at(r[2], r[1]), Paint()
          ..color = const Color(0xFF8A6440).withOpacity(.55 * lit)
          ..strokeWidth = 1.1);
        canvas.drawLine(at(r[0], r[1]), at(r[0], r[3]), Paint()
          ..color = const Color(0xFF6A4A30).withOpacity(.35 * lit)
          ..strokeWidth = 1);
        canvas.drawLine(at(r[0], r[3]), at(r[2], r[3]), Paint()
          ..color = Colors.black.withOpacity(.7)
          ..strokeWidth = 1.4);
        canvas.drawLine(at(r[2], r[1]), at(r[2], r[3]), Paint()
          ..color = Colors.black.withOpacity(.5)
          ..strokeWidth = 1.2);
      }
      // brass knob, backplate and keyhole, with a highlight from the bulb
      final k = at(0.86, 0.52);
      final kr = math.max(2.0, d.width * 0.045 * depth);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: k + Offset(0, kr * 1.4), width: kr * 1.3, height: kr * 5.2), Radius.circular(kr * .5)),
          Paint()..color = const Color(0xFF6B5320).withOpacity(lit));
      canvas.drawCircle(k, kr, Paint()..shader = ui.Gradient.radial(k - Offset(kr * .35, kr * .4), kr * 1.2, [
        const Color(0xFFFFE7A0).withOpacity(lit),
        const Color(0xFFB08A2E).withOpacity(lit),
        const Color(0xFF4A3712).withOpacity(lit),
      ], const [0, .45, 1]));
      canvas.drawOval(Rect.fromCenter(center: k + Offset(0, kr * 2.7), width: kr * .35, height: kr * .7), Paint()..color = Colors.black.withOpacity(.85));
      // the leading edge catches the stairwell light as it opens
      if (open > 0.02) {
        canvas.drawLine(at(1, 0), at(1, 1), Paint()
          ..color = _warm.withOpacity(.55 * math.min(1, open * 4))
          ..strokeWidth = 1.4);
      }
      canvas.restore();
    }

    // light under the door, with a shadow crossing behind it
    if (open < 1) {
      final strip = Paint()..strokeWidth = 2;
      const n = 40;
      for (var i = 0; i < n; i++) {
        final x0 = d.left + d.width * i / n, x1 = d.left + d.width * (i + 1) / n;
        final mid = (i + .5) / n;
        final sx = -0.3 + 1.6 * shadowPass;
        final shade = (shadowPass > 0 && shadowPass < 1) ? 1 - 0.92 * math.exp(-math.pow((mid - sx) / 0.13, 2)) : 1.0;
        strip.color = _gold.withOpacity((0.35 + 0.6 * under) * shade * (1 - open));
        canvas.drawLine(Offset(x0, d.bottom - 1), Offset(x1, d.bottom - 1), strip);
      }
      // a thin line of light down the latch side once it's ajar
      if (open > 0.005 && open < 0.5) {
        canvas.drawLine(Offset(rx + 1, d.top + 2), Offset(rx + 1, d.bottom - 2), Paint()
          ..color = _warm.withOpacity(.8)
          ..strokeWidth = 1.2 + open * 10
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      }
    }

    // ---------- casing around the doorway ----------
    final cw = d.width * 0.075;
    final casing = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTRB(d.left - cw, d.top - cw * 1.3, d.right + cw, d.bottom))
      ..addRect(d);
    canvas.drawPath(casing, Paint()..color = Color.lerp(Colors.black, const Color(0xFF2A2018), 0.4 + 0.6 * bulb)!);
    canvas.drawLine(Offset(d.left - cw, d.top - cw * 1.3), Offset(d.right + cw, d.top - cw * 1.3), Paint()
      ..color = const Color(0xFF6A5038).withOpacity(.6 * bulb)
      ..strokeWidth = 1.2);
    canvas.drawRect(d, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.black.withOpacity(.8));
  }

  /// A stairwell going down and away: plaster walls, a sloping ceiling, steps with a
  /// stepped stringer on each wall, a handrail, and warm light from somewhere far below.
  void _stairwell(Canvas canvas, Rect d) {
    final vp = g.stairVp, hz = g.stairHorizon;
    canvas.drawRect(d, Paint()..color = Colors.black);
    if (open <= 0) return;

    const n = 15;
    final f = [for (var i = 0; i <= n; i++) math.pow(0.83, i).toDouble()];
    Offset sec(Offset corner, double k) => vp + (corner - vp) * k;

    // the back of each tread sits directly above the next nosing, on the line to eye level
    Offset back(Offset nose, Offset nextNose) {
      final s = (nextNose.dx - nose.dx) / (hz.dx - nose.dx);
      return Offset(nextNose.dx, nose.dy + (hz.dy - nose.dy) * s);
    }

    final L = [for (final k in f) sec(d.bottomLeft, k)];
    final R = [for (final k in f) sec(d.bottomRight, k)];
    final glow = (double k) => (1 - k) * open; // deeper = closer to the light

    // walls with the stepped stringer along the bottom
    for (final isLeft in [true, false]) {
      final P = isLeft ? L : R;
      final top0 = isLeft ? d.topLeft : d.topRight;
      final path = Path()..moveTo(top0.dx, top0.dy);
      final topN = sec(top0, f[n]);
      path.lineTo(topN.dx, topN.dy);
      path.lineTo(P[n].dx, P[n].dy);
      for (var i = n - 1; i >= 0; i--) {
        final bk = back(P[i], P[i + 1]);
        path.lineTo(bk.dx, bk.dy);
        path.lineTo(P[i].dx, P[i].dy);
      }
      path.close();
      canvas.drawPath(
          path,
          Paint()
            ..shader = ui.Gradient.linear(isLeft ? d.centerLeft : d.centerRight, vp, [
              const Color(0xFF060607),
              Color.lerp(const Color(0xFF0B0A0A), const Color(0xFF4A3420), .75 * open)!,
            ]));
    }
    // sloping ceiling
    canvas.drawPath(_quad(d.topLeft, d.topRight, sec(d.topRight, f[n]), sec(d.topLeft, f[n])), Paint()
      ..shader = ui.Gradient.linear(d.topCenter, vp, [Colors.black, Color.lerp(Colors.black, const Color(0xFF2A1E14), open)!]));

    // the far landing, lit
    final farRect = Rect.fromPoints(sec(d.topLeft, f[n]), sec(d.bottomRight, f[n]));
    canvas.drawRect(farRect, Paint()..color = Color.lerp(Colors.black, const Color(0xFFB8793A), .8 * open)!);

    // treads, deepest first so nearer steps cover the drop behind them
    for (var i = n - 1; i >= 0; i--) {
      final bl = back(L[i], L[i + 1]), br = back(R[i], R[i + 1]);
      final g0 = glow(f[i]);
      canvas.drawPath(
          _quad(L[i], R[i], br, bl),
          Paint()
            ..shader = ui.Gradient.linear(Offset(0, L[i].dy), Offset(0, bl.dy), [
              Color.lerp(const Color(0xFF0A0908), const Color(0xFF6E4B2A), g0 * .9)!,
              Color.lerp(const Color(0xFF050404), const Color(0xFF3A2816), g0 * .9)!,
            ]));
      // nosing catching the light
      canvas.drawLine(L[i], R[i], Paint()
        ..color = const Color(0xFFFFC985).withOpacity(.08 + .45 * g0)
        ..strokeWidth = 1);
      // shadow where the step drops away
      canvas.drawLine(bl, br, Paint()
        ..color = Colors.black.withOpacity(.85)
        ..strokeWidth = 1.2);
    }

    // glow rising from below
    canvas.drawCircle(vp, d.width * 0.95, Paint()
      ..shader = ui.Gradient.radial(vp, d.width * 0.95, [_warm.withOpacity(.45 * open), _warm.withOpacity(.10 * open), Colors.transparent], const [0, .4, 1]));

    // handrail on the right wall, parallel to the stairs
    final railH = d.height * 0.36;
    final r0 = R[0] - Offset(d.width * 0.04, railH);
    final r1 = sec(R[0] - Offset(d.width * 0.04, railH), f[n]);
    canvas.drawLine(r0, r1, Paint()
      ..color = const Color(0xFF8A6238).withOpacity(.75 * open)
      ..strokeWidth = 2.2);
    for (var i = 0; i < n; i += 3) {
      final p = vp + (r0 - vp) * f[i];
      canvas.drawLine(p, p + Offset(d.width * 0.03 * f[i], 0), Paint()
        ..color = const Color(0xFF3A2A1A).withOpacity(open)
        ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_HallwayPainter old) => true;
}

/// Film grain and a vignette that sit over everything (not part of the camera move).
class _GrainPainter extends CustomPainter {
  _GrainPainter({required this.frame});
  final int frame;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.Random(frame);
    final light = <Offset>[], dark = <Offset>[];
    final count = (size.width * size.height / 260).clamp(800, 5000).toInt();
    for (var i = 0; i < count; i++) {
      final p = Offset(r.nextDouble() * size.width, r.nextDouble() * size.height);
      (i.isEven ? light : dark).add(p);
    }
    canvas.drawPoints(ui.PointMode.points, light, Paint()
      ..color = Colors.white.withOpacity(.05)
      ..strokeWidth = 1.2);
    canvas.drawPoints(ui.PointMode.points, dark, Paint()
      ..color = Colors.black.withOpacity(.25)
      ..strokeWidth = 1.2);
    final c = size.center(Offset.zero);
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(c, size.longestSide * 0.62, [Colors.transparent, Colors.black.withOpacity(.82)], const [0.45, 1]));
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.frame != frame;
}
