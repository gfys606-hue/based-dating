import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';

/// The opening: a dark hallway, a door with light under it. "The Door" appears,
/// the door swings open onto a dark stairwell going down, "is not for everyone."
/// fades up, and you walk through the doorway into the app. Tap anywhere to skip.
/// Plays once each time the app is opened.
class DoorIntro extends StatefulWidget {
  const DoorIntro({super.key, required this.child});
  final Widget child;

  static bool _played = false; // once per launch (survives light/dark rebuilds)

  @override
  State<DoorIntro> createState() => _DoorIntroState();
}

class _DoorIntroState extends State<DoorIntro> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200));
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
    Future<void>.delayed(const Duration(milliseconds: 450), () {
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
        duration: const Duration(milliseconds: 450),
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

  Widget _scene(BuildContext context, double t) {
    final size = MediaQuery.of(context).size;
    final g = _Geometry(size);

    final fadeIn = _seg(t, 0.0, 0.12, Curves.easeOut);
    final open = _seg(t, 0.30, 0.62, Curves.easeInOutCubic);
    final word1 = _seg(t, 0.10, 0.26, Curves.easeOut);
    final word2 = _seg(t, 0.46, 0.62, Curves.easeOut);
    final walk = _seg(t, 0.72, 0.98, Curves.easeInCubic);
    final textOut = 1 - _seg(t, 0.72, 0.80);
    final black = _seg(t, 0.88, 1.0);

    final zoom = 1 + walk * 9;
    final focus = g.doorCenter;

    final serif = GoogleFonts.cormorantGaramond(color: B.gold, fontWeight: FontWeight.w700, height: 1.0);

    return Material(
      color: const Color(0xFF03040A),
      child: Stack(fit: StackFit.expand, children: [
        Opacity(
          opacity: fadeIn,
          child: Transform(
            alignment: Alignment.topLeft,
            transform: Matrix4.identity()
              ..translate(focus.dx, focus.dy)
              ..scale(zoom, zoom)
              ..translate(-focus.dx, -focus.dy),
            child: CustomPaint(painter: _HallwayPainter(g, open: open, flicker: t)),
          ),
        ),
        // The words, on the hallway floor
        Positioned(
          left: 24,
          right: 24,
          top: g.textTop,
          child: Opacity(
            opacity: textOut,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Opacity(
                opacity: word1,
                child: Transform.translate(
                  offset: Offset(0, 10 * (1 - word1)),
                  child: Text('The Door',
                      textAlign: TextAlign.center,
                      style: serif.copyWith(fontSize: math.min(56, size.width * 0.14), letterSpacing: 1.5, shadows: [
                        Shadow(color: B.gold.withOpacity(.45 * word1), blurRadius: 24),
                      ])),
                ),
              ),
              const SizedBox(height: 10),
              Opacity(
                opacity: word2,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - word2)),
                  child: Text('is not for everyone.',
                      textAlign: TextAlign.center,
                      style: serif.copyWith(
                          fontSize: math.min(30, size.width * 0.075),
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFE9DFC4))),
                ),
              ),
            ]),
          ),
        ),
        if (black > 0) ColoredBox(color: Colors.black.withOpacity(black)),
        // Quiet skip hint
        Positioned(
          bottom: 28 + MediaQuery.of(context).padding.bottom,
          left: 0,
          right: 0,
          child: Opacity(
            opacity: 0.35 * fadeIn * textOut,
            child: Text('tap to enter',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(color: Colors.white, fontSize: 11, letterSpacing: 3, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}

/// Where everything sits, from the screen size. Shared by the painter and the zoom.
class _Geometry {
  _Geometry(this.size) {
    final w = size.width, h = size.height;
    final bw = math.min(w * 0.40, h * 0.26); // back wall of the hallway
    final bh = bw * 1.55;
    final cx = w / 2, cy = h * 0.40;
    back = Rect.fromCenter(center: Offset(cx, cy), width: bw, height: bh);
    final dw = bw * 0.56, dh = bh * 0.80;
    door = Rect.fromLTWH(cx - dw / 2, back.bottom - dh, dw, dh);
    textTop = math.min(h * 0.70, back.bottom + (h - back.bottom) * 0.42);
  }
  final Size size;
  late final Rect back;
  late final Rect door;
  late final double textTop;
  Offset get doorCenter => door.center;
}

class _HallwayPainter extends CustomPainter {
  _HallwayPainter(this.g, {required this.open, required this.flicker});
  final _Geometry g;
  final double open; // 0 closed .. 1 open
  final double flicker;

  static const _gold = Color(0xFFF5C542);
  static const _warm = Color(0xFFFFB347);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final b = g.back, d = g.door;

    Path quad(Offset a, Offset b2, Offset c, Offset d2) =>
        Path()..moveTo(a.dx, a.dy)..lineTo(b2.dx, b2.dy)..lineTo(c.dx, c.dy)..lineTo(d2.dx, d2.dy)..close();

    // ---- hallway: ceiling, walls, floor converging on the back wall ----
    final ceiling = quad(Offset.zero, Offset(w, 0), b.topRight, b.topLeft);
    final floor = quad(Offset(0, h), Offset(w, h), b.bottomRight, b.bottomLeft);
    final left = quad(Offset.zero, b.topLeft, b.bottomLeft, Offset(0, h));
    final right = quad(Offset(w, 0), b.topRight, b.bottomRight, Offset(w, h));

    canvas.drawPath(
        ceiling,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: const [Color(0xFF020309), Color(0xFF0A0D1C)])
              .createShader(Rect.fromLTRB(0, 0, w, b.top)));
    canvas.drawPath(
        floor,
        Paint()
          ..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: const [Color(0xFF040509), Color(0xFF12131C)])
              .createShader(Rect.fromLTRB(0, b.bottom, w, h)));
    for (final p in [left, right]) {
      final isLeft = identical(p, left);
      canvas.drawPath(
          p,
          Paint()
            ..shader = LinearGradient(
              begin: isLeft ? Alignment.centerLeft : Alignment.centerRight,
              end: isLeft ? Alignment.centerRight : Alignment.centerLeft,
              colors: const [Color(0xFF030409), Color(0xFF0E1222)],
            ).createShader(Rect.fromLTRB(isLeft ? 0 : b.right, 0, isLeft ? b.left : w, h)));
    }
    // floorboards running toward the door
    final boards = Paint()
      ..color = const Color(0xFF1B1C26).withOpacity(.55)
      ..strokeWidth = 1;
    for (var i = 1; i < 8; i++) {
      final f = i / 8;
      canvas.drawLine(Offset(w * f, h), Offset(b.left + b.width * f, b.bottom), boards);
    }
    // wainscot rail along both walls
    final rail = Paint()
      ..color = const Color(0xFF242638).withOpacity(.6)
      ..strokeWidth = 1.2;
    final railY = b.top + b.height * 0.55;
    canvas.drawLine(Offset(0, h * 0.62), Offset(b.left, railY), rail);
    canvas.drawLine(Offset(w, h * 0.62), Offset(b.right, railY), rail);

    // back wall
    canvas.drawRect(b, Paint()..color = const Color(0xFF0F1220));

    // one dim bulb above the door
    final bulb = Offset(b.center.dx, b.top + b.height * 0.06);
    final hum = 0.92 + 0.08 * math.sin(flicker * 40); // a faint flicker
    canvas.drawCircle(
        bulb,
        b.width * 1.1,
        Paint()
          ..shader = RadialGradient(colors: [_warm.withOpacity(.16 * hum), _warm.withOpacity(0)])
              .createShader(Rect.fromCircle(center: bulb, radius: b.width * 1.1)));
    canvas.drawCircle(bulb, 2.2, Paint()..color = const Color(0xFFFFE2A8).withOpacity(.9 * hum));

    // ---- doorway: the stairwell behind the door ----
    canvas.save();
    canvas.clipRect(d);
    _stairwell(canvas, d);
    canvas.restore();

    // light spilling out onto the hallway floor as it opens
    if (open > 0) {
      final spill = quad(d.bottomLeft, d.bottomRight, Offset(d.right + d.width * 1.6, h), Offset(d.left - d.width * 0.3, h));
      canvas.drawPath(
          spill,
          Paint()
            ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
              _warm.withOpacity(.20 * open),
              _warm.withOpacity(0),
            ]).createShader(Rect.fromLTRB(d.left, d.bottom, d.right, h)));
    }

    // ---- the door itself, hinged on the left, swinging inward ----
    final angle = open * 1.35; // ~77°
    final reach = math.cos(angle);
    final depth = 1 / (1 + math.sin(angle) * 0.55);
    final rx = d.left + d.width * reach;
    final halfH = d.height / 2 * depth;
    final panel = quad(d.topLeft, Offset(rx, d.center.dy - halfH), Offset(rx, d.center.dy + halfH), d.bottomLeft);
    final shade = 1 - open * 0.55;
    canvas.drawPath(
        panel,
        Paint()
          ..shader = LinearGradient(colors: [
            Color.lerp(const Color(0xFF000000), const Color(0xFF2A1D14), shade)!,
            Color.lerp(const Color(0xFF000000), const Color(0xFF1C130D), shade)!,
          ]).createShader(d));
    if (open < 0.98) {
      // panel insets
      final inset = Paint()
        ..color = const Color(0xFF3A2A1C).withOpacity(.55 * shade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (final r in [
        [0.14, 0.08, 0.86, 0.44],
        [0.14, 0.52, 0.86, 0.92],
      ]) {
        Offset at(double fx, double fy) {
          final x = d.left + (rx - d.left) * fx;
          final hh = d.height / 2 * (1 + (depth - 1) * fx);
          return Offset(x, d.center.dy - hh + 2 * hh * fy);
        }

        canvas.drawPath(quad(at(r[0], r[1]), at(r[2], r[1]), at(r[2], r[3]), at(r[0], r[3])), inset);
      }
      // brass knob
      final kx = d.left + (rx - d.left) * 0.86;
      canvas.drawCircle(Offset(kx, d.center.dy + d.height * 0.05), math.max(1.5, d.width * 0.035 * depth),
          Paint()..color = _gold.withOpacity(.85 * shade));
    }
    // light under the door before it opens
    if (open < 1) {
      canvas.drawLine(
          Offset(d.left + 2, d.bottom - 0.5),
          Offset(d.right - 2, d.bottom - 0.5),
          Paint()
            ..color = _gold.withOpacity(.75 * (1 - open))
            ..strokeWidth = 1.6
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    }
    // frame
    canvas.drawRect(
        d.inflate(1.5),
        Paint()
          ..color = const Color(0xFF2B2418)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
  }

  /// Dark steps going down and away, a warm glow far below.
  void _stairwell(Canvas canvas, Rect d) {
    canvas.drawRect(d, Paint()..color = const Color(0xFF030306));
    final vp = Offset(d.center.dx + d.width * 0.08, d.top + d.height * 0.30); // where the stairs vanish
    canvas.drawCircle(
        vp,
        d.width * 0.9,
        Paint()
          ..shader = RadialGradient(colors: [_warm.withOpacity(.32 * open), _warm.withOpacity(.06 * open), Colors.transparent], stops: const [0, .45, 1])
              .createShader(Rect.fromCircle(center: vp, radius: d.width * 0.9)));

    const n = 11;
    for (var i = 0; i < n; i++) {
      final f0 = math.pow(0.80, i).toDouble();
      final f1 = math.pow(0.80, i + 1).toDouble();
      Offset lerp(Offset edge, double f) => Offset(vp.dx + (edge.dx - vp.dx) * f, vp.dy + (edge.dy - vp.dy) * f);
      final l0 = lerp(d.bottomLeft, f0), r0 = lerp(d.bottomRight, f0);
      final l1 = lerp(d.bottomLeft, f1), r1 = lerp(d.bottomRight, f1);
      final tread = Path()..moveTo(l0.dx, l0.dy)..lineTo(r0.dx, r0.dy)..lineTo(r1.dx, r1.dy)..lineTo(l1.dx, l1.dy)..close();
      final lit = (1 - f0) * open; // deeper steps catch more of the glow
      canvas.drawPath(tread, Paint()..color = Color.lerp(const Color(0xFF07070B), const Color(0xFF2B2015), lit * 0.9)!);
      canvas.drawLine(l1, r1, Paint()
        ..color = _warm.withOpacity(.10 + .35 * lit)
        ..strokeWidth = 0.8);
    }
    // handrail down the right side
    canvas.drawLine(Offset(d.right - d.width * 0.06, d.top + d.height * 0.55), vp + Offset(d.width * 0.05, -d.height * 0.02),
        Paint()
          ..color = const Color(0xFF3A2C1C).withOpacity(.8)
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_HallwayPainter old) => old.open != open || old.flicker != flicker;
}
