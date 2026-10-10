import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import 'door_intro_plate.dart';

/// The opening (about 11 seconds, tap to skip), built from rendered images
/// (tools/intro_render/study.py): a dim study lined with bookcases. The lamps come up,
/// one red book tilts out like a lever, a seam of light traces the middle bookcase,
/// it cracks open, holds, then swings wide onto a stairwell going down. "The Door"
/// rises out of the stairwell, then "is not for everyone.", and you walk through and down.
/// Plays once each time the app is opened.
class DoorIntro extends StatefulWidget {
  const DoorIntro({super.key, required this.child});
  final Widget child;

  static bool _played = false; // once per launch (survives light/dark rebuilds)

  @override
  State<DoorIntro> createState() => _DoorIntroState();
}

class _Imgs {
  _Imgs(this.closed, this.open, this.stairs, this.dClosed, this.dOpen, this.dStairs, this.program);
  final ui.Image closed, open, stairs;
  final ui.Image dClosed, dOpen, dStairs; // depth maps for parallax
  final ui.FragmentProgram? program; // null if the device can't run the shader: falls back to flat
}

class _DoorIntroState extends State<DoorIntro> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 11000));
  bool _show = !DoorIntro._played;
  bool _fading = false;
  _Imgs? _imgs;

  @override
  void initState() {
    super.initState();
    if (!_show) return;
    DoorIntro._played = true;
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    _load();
  }

  Future<ui.Image> _img(String name) async {
    final data = await rootBundle.load('assets/intro/$name');
    return decodeImageFromList(data.buffer.asUint8List());
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        _img('hall_closed.jpg'), _img('hall_open.jpg'), _img('stairs.jpg'),
        _img('depth_closed.png'), _img('depth_open.png'), _img('depth_stairs.png'),
      ]).timeout(const Duration(seconds: 6));
      ui.FragmentProgram? program;
      try {
        program = await ui.FragmentProgram.fromAsset('shaders/parallax.frag');
      } catch (_) {}
      if (!mounted) return;
      setState(() => _imgs = _Imgs(r[0], r[1], r[2], r[3], r[4], r[5], program));
      if (MediaQuery.of(context).disableAnimations) {
        _finish(); // people who turned off animations on their phone go straight in
      } else {
        _c.forward();
      }
    } catch (_) {
      _finish(); // never hold the app hostage to the intro
    }
  }

  void _finish() {
    if (_fading || !mounted) return;
    setState(() => _fading = true);
    Future<void>.delayed(const Duration(milliseconds: 600), () {
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
    // The app keeps the same spot in the tree before and after, so it isn't rebuilt from scratch
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      if (_show)
        AnimatedOpacity(
          opacity: _fading ? 0 : 1,
          duration: const Duration(milliseconds: 600),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _finish,
            child: ColoredBox(
              color: Colors.black,
              child: _imgs == null
                  ? const SizedBox.expand()
                  : AnimatedBuilder(
                      animation: _c,
                      builder: (context, _) => CustomPaint(
                        size: Size.infinite,
                        painter: _IntroPainter(_imgs!, _c.value,
                            pad: MediaQuery.of(context).padding,
                            big: GoogleFonts.cormorantGaramond(fontWeight: FontWeight.w700),
                            small: GoogleFonts.cormorantGaramond(fontWeight: FontWeight.w600, fontStyle: FontStyle.italic),
                            hint: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                      ),
                    ),
            ),
          ),
        ),
    ]);
  }
}

double _seg(double t, double a, double b, [Curve curve = Curves.linear]) =>
    curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

/// The lamps coming up, with a faint flicker; they dip for a moment when the case unlatches.
double _bulb(double t) {
  if (t < 0.03) return 0;
  final up = _seg(t, 0.03, 0.12, Curves.easeInOut);
  final flicker = 0.96 + 0.04 * math.sin(t * 220) * math.sin(t * 37);
  final dip = (t > 0.395 && t < 0.41) ? 0.6 : 1.0;
  return up * flicker * dip;
}

class _IntroPainter extends CustomPainter {
  _IntroPainter(this.imgs, this.t, {required this.pad, required this.big, required this.small, required this.hint});
  final _Imgs imgs;
  final double t;
  final EdgeInsets pad;
  final TextStyle big, small, hint;

  static const _warm = Color(0xFFFFAE52);
  static const _size = DoorPlate.size;
  static const _doorway = Rect.fromLTRB(DoorPlate.dwL, DoorPlate.dwT, DoorPlate.dwR, DoorPlate.dwB);
  static const _door = Rect.fromLTRB(DoorPlate.dfL, DoorPlate.dfT, DoorPlate.dfR, DoorPlate.dfB);
  static const _stairs = Offset(DoorPlate.stX, DoorPlate.stY);
  static const _lever = Rect.fromLTRB(DoorPlate.lbL, DoorPlate.lbT, DoorPlate.lbR, DoorPlate.lbB);

  /// Draws a rendered still as seen from a camera moved by [cam] (metres), using its depth
  /// map so nearer things shift more. Falls back to a flat zoom if shaders aren't available.
  void _plate(Canvas canvas, Size canvasSize, Rect rect, ui.Image a, ui.Image b, ui.Image da, ui.Image db,
      {required List<double> cam, required double focal, double mix = 0, Rect? door, bool doorOpen = false, double opacity = 1}) {
    final prog = imgs.program;
    if (opacity < 1) canvas.saveLayer(rect.inflate(2), Paint()..color = Colors.black.withOpacity(opacity));
    if (prog != null) {
      final sh = prog.fragmentShader();
      final d = door ?? Rect.zero;
      var i = 0;
      for (final v in [canvasSize.width, canvasSize.height, rect.left, rect.top, rect.width, rect.height, cam[0], cam[1], cam[2], focal, mix,
        d.left, d.top, d.right, d.bottom, doorOpen ? 1.0 : 0.0]) {
        sh.setFloat(i++, v);
      }
      sh.setImageSampler(0, a);
      sh.setImageSampler(1, b);
      sh.setImageSampler(2, da);
      sh.setImageSampler(3, db);
      canvas.drawRect(rect, Paint()..shader = sh);
    } else {
      // flat fallback: zoom as if everything sat at the bookcase's depth
      final sc = DoorPlate.frontDepth / math.max(DoorPlate.frontDepth - cam[2], 0.3);
      canvas.save();
      canvas.translate(rect.center.dx, rect.center.dy);
      canvas.scale(sc);
      canvas.translate(-rect.center.dx, -rect.center.dy);
      final src = Rect.fromLTWH(0, 0, a.width.toDouble(), a.height.toDouble());
      final q = Paint()..filterQuality = FilterQuality.medium;
      canvas.drawImageRect(a, src, rect, q);
      if (mix > 0) canvas.drawImageRect(b, src, rect, Paint()..color = Colors.white.withOpacity(mix.clamp(0.0, 1.0)));
      if (doorOpen && door != null) {
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(rect.left + door.left * rect.width, rect.top + door.top * rect.height,
            rect.left + door.right * rect.width, rect.top + door.bottom * rect.height));
        canvas.drawImageRect(b, src, rect, q);
        canvas.restore();
      }
      canvas.restore();
    }
    if (opacity < 1) canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bulb = _bulb(t);
    // the red book tilts out, a click, a seam of light, the case cracks open, holds, swings
    final lever = _seg(t, 0.19, 0.27, Curves.easeOutBack) * (1 - _seg(t, 0.40, 0.43));
    final seam = _seg(t, 0.29, 0.40, Curves.easeIn);
    final open = t < 0.50 ? 0.06 * _seg(t, 0.40, 0.45, Curves.easeOut) : 0.06 + 0.94 * _seg(t, 0.50, 0.64, Curves.easeInOutCubic);
    final walk = _seg(t, 0.86, 0.97, Curves.easeInCubic);
    final toStairs = _seg(t, 0.90, 0.955, Curves.easeInOut);
    final black = _seg(t, 0.955, 1.0);

    // The camera, in metres: a slow walk in with a slight drift to one side (that drift is what
    // makes the depth read), then straight through the opening.
    final approach = _seg(t, 0.0, 0.62, Curves.easeInOut);
    final tz = 0.95 * approach + 2.9 * walk;
    final tx = (-0.24 + 0.34 * approach) * (1 - walk);
    final ty = -0.05 * approach;
    final cam = [tx, ty, tz];

    // Fit the square images so they always cover top to bottom (portrait crops the sides);
    // on wide screens grow until they're at least 60% of the width.
    final s = math.max(h * 1.26, w * 0.6);
    final k = s / _size;
    final doorC = _doorway.center;
    final base = Offset(w / 2 - doorC.dx * k, h * 0.44 - doorC.dy * k); // doorway a little above the middle
    final plateRect = Rect.fromLTWH(base.dx, base.dy, s, s);
    final doorUv = Rect.fromLTRB(_door.left / _size, _door.top / _size, _door.right / _size, _door.bottom / _size);

    // where a point in the image at depth [d] lands once the camera has moved
    const pp = Offset(_size / 2, _size / 2);
    const fpx = DoorPlate.focal;
    Offset moved(Offset p, double d) {
      final dz = math.max(d - tz, 0.3);
      return pp + (p - pp) * (d / dz) + Offset(-fpx * tx / dz, fpx * ty / dz);
    }
    Offset onScreen(Offset p, double d) => base + moved(p, d) * k;

    // 1. the room, rendered with real depth; the stairwell's light spills in as the case opens
    _plate(canvas, size, plateRect, imgs.closed, imgs.open, imgs.dClosed, imgs.dOpen,
        cam: cam, focal: fpx / _size, mix: open.clamp(0.0, 1.0), door: doorUv, doorOpen: open > 0);
    // the lamps' flicker darkens what they light (the stairwell keeps its own light)
    final dim = (1 - bulb) * (1 - open * 0.6);
    if (dim > 0) canvas.drawRect(plateRect.inflate(4), Paint()..color = Colors.black.withOpacity(dim.clamp(0.0, 1.0)));

    // soft edges, so wide screens don't show a hard square
    final feather = s * 0.16;
    for (final r in [
      [Rect.fromLTWH(plateRect.left, plateRect.top, feather, s), Alignment.centerLeft, Alignment.centerRight],
      [Rect.fromLTWH(plateRect.right - feather, plateRect.top, feather, s), Alignment.centerRight, Alignment.centerLeft],
      [Rect.fromLTWH(plateRect.left, plateRect.bottom - feather, s, feather), Alignment.bottomCenter, Alignment.topCenter],
      [Rect.fromLTWH(plateRect.left, plateRect.top, s, feather), Alignment.topCenter, Alignment.bottomCenter],
    ]) {
      final rect = r[0] as Rect;
      canvas.drawRect(
          rect.inflate(1),
          Paint()
            ..shader = LinearGradient(begin: r[1] as Alignment, end: r[2] as Alignment, colors: const [Colors.black, Colors.transparent])
                .createShader(rect));
    }

    // Everything on the bookcase moves with it: image pixels -> screen, at the bookcase's depth.
    const dF = DoorPlate.frontDepth;
    final sF = dF / math.max(dF - tz, 0.3);
    final offF = Offset(-fpx * tx / math.max(dF - tz, 0.3), fpx * ty / math.max(dF - tz, 0.3));
    canvas.save();
    canvas.translate(base.dx, base.dy);
    canvas.scale(k);
    canvas.translate(pp.dx + offF.dx, pp.dy + offF.dy);
    canvas.scale(sF);
    canvas.translate(-pp.dx, -pp.dy);
    final q = Paint()..filterQuality = FilterQuality.medium;

    final df = _door;
    // 3a. the lever: one red book tilts out from the shelf (and springs back as the case moves)
    if (lever > 0) {
      final lb = _lever;
      canvas.drawRect(lb, Paint()..color = Colors.black.withOpacity(0.85 * lever.clamp(0.0, 1.0))); // the gap it leaves
      canvas.save();
      canvas.translate(lb.center.dx, lb.bottom);
      final tilt = Matrix4.identity()
        ..setEntry(3, 2, 1 / DoorPlate.focal)
        ..rotateX(0.7 * lever);
      canvas.transform(tilt.storage);
      canvas.drawImageRect(imgs.closed, lb, Rect.fromLTWH(-lb.width / 2, -lb.height, lb.width, lb.height), q);
      canvas.restore();
    }
    // 3b. a seam of light traces the edges of the hidden door
    if (seam > 0 && open < 1) {
      final glow = Paint()
        ..color = _warm.withOpacity((0.75 * seam * (1 - open)).clamp(0.0, 1.0))
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      final path = Path()
        ..moveTo(df.left, df.bottom)
        ..lineTo(df.left, df.top)
        ..lineTo(df.right, df.top)
        ..lineTo(df.right, df.bottom);
      canvas.drawPath(path, glow);
      canvas.drawPath(path, Paint()
        ..color = const Color(0xFFFFE2B0).withOpacity((0.55 * seam * (1 - open)).clamp(0.0, 1.0))
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(df.center.dx, df.bottom + 10), width: df.width * 1.3, height: 34),
          Paint()
            ..color = _warm.withOpacity((0.16 * seam * (1 - open)).clamp(0.0, 1.0))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16));
    }

    // 4. the bookcase: a solid case, hinged on the left, swinging away in true perspective.
    final angle = open * 1.40; // up to ~80°
    final caseDepthPx = DoorPlate.focal * 0.34 / dF; // the case is 34 cm deep
    canvas.save();
    canvas.translate(df.left, df.center.dy);
    final m = Matrix4.identity()
      ..setEntry(3, 2, 1 / DoorPlate.focal)
      ..rotateY(-angle);
    // its free side: solid wood, swinging into view as it opens
    if (angle > 0.01) {
      canvas.save();
      final side = m.clone()
        ..translate(df.width, 0.0, 0.0)
        ..rotateY(-math.pi / 2);
      canvas.transform(side.storage);
      final sideRect = Rect.fromLTWH(0, -df.height / 2, caseDepthPx, df.height);
      canvas.drawRect(
          sideRect,
          Paint()
            ..shader = LinearGradient(colors: [
              Color.lerp(const Color(0xFF3A2414), const Color(0xFF7A4E2C), math.min(1.0, open * 1.4))!,
              const Color(0xFF1A0F08),
            ]).createShader(sideRect));
      // the edge nearest us catches the stairwell light
      canvas.drawRect(Rect.fromLTWH(0, -df.height / 2, 2.5, df.height), Paint()..color = _warm.withOpacity(0.5 * math.min(1.0, open * 4)));
      canvas.restore();
    }
    canvas.transform(m.storage);
    final doorDst = Rect.fromLTWH(0, -df.height / 2, df.width, df.height);
    canvas.drawImageRect(imgs.closed, df, doorDst, q);
    // turning away from the lamps it falls into shadow; the flicker applies too
    final dark = (math.sin(angle) * 0.7 + dim).clamp(0.0, 1.0); // dark with the room before the lamps come up
    if (dark > 0) canvas.drawRect(doorDst, Paint()..color = Colors.black.withOpacity(dark));
    canvas.restore();
    // a blade of light down the latch side while it's only ajar
    if (open > 0.003 && open < 0.4) {
      final edgeX = df.left + df.width * math.cos(angle) / (1 + df.width * math.sin(angle) / DoorPlate.focal);
      canvas.drawRect(
          Rect.fromLTRB(edgeX, df.top + 4, df.right, df.bottom),
          Paint()
            ..color = _warm.withOpacity((0.35 * (1 - open * 2)).clamp(0.0, 1.0))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    }
    canvas.restore();

    // 5. through the opening and down the stairs (its own shot, also moving through depth)
    if (toStairs > 0) {
      final sz = math.max(w, h) * 1.05;
      final r = Rect.fromCenter(center: Offset(w / 2, h / 2), width: sz, height: sz);
      final down = _seg(t, 0.90, 1.0, Curves.easeIn);
      _plate(canvas, size, r, imgs.stairs, imgs.stairs, imgs.dStairs, imgs.dStairs,
          cam: [0.0, -0.1 * down, 1.1 * down], focal: DoorPlate.stairsFocal, opacity: toStairs);
    }

    // 6. the words rise out of the stairwell once the door is open
    final textOut = 1 - _seg(t, 0.86, 0.90);
    final from = onScreen(_stairs, DoorPlate.stairsDepth);
    final doorBottom = onScreen(Offset(df.center.dx, df.bottom), dF).dy;
    final bigSize = math.min(76.0, w * 0.165);
    final finalY = math.min(h - pad.bottom - bigSize * 1.9, math.max(doorBottom + bigSize * 0.75, h * 0.72));
    final rise = _seg(t, 0.62, 0.78, Curves.easeOutCubic);
    final second = _seg(t, 0.70, 0.82, Curves.easeOut);
    _rise(canvas, size, 'The Door', big.copyWith(fontSize: bigSize, letterSpacing: 2, color: B.gold), rise, rise,
        from, Offset(w / 2, finalY), textOut);
    _rise(canvas, size, 'is not for everyone.', small.copyWith(fontSize: bigSize * 0.48, color: const Color(0xFFEDE3C8)), rise,
        second, from + Offset(0, bigSize * 0.92 * 0.12), Offset(w / 2, finalY + bigSize * 0.92), textOut);

    // 7. film grain and a heavy vignette
    _grain(canvas, size);

    // tap to skip
    final hintA = 0.30 * _seg(t, 0.05, 0.12) * (1 - _seg(t, 0.55, 0.6));
    if (hintA > 0) {
      final tp = TextPainter(
          text: TextSpan(
              text: 'TAP TO ENTER',
              style: hint.copyWith(fontSize: 10.5, letterSpacing: 3.2, color: Colors.white.withOpacity(hintA))),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(w / 2 - tp.width / 2, h - pad.bottom - 34));
    }

    if (black > 0) canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black.withOpacity(black));
  }

  /// A line of text that starts small and dim deep in the stairwell and rises toward you.
  void _rise(Canvas canvas, Size size, String text, TextStyle style, double p, double show, Offset from, Offset to, double fade) {
    fade *= show;
    if (p <= 0 || fade <= 0) return;
    final pos = Offset.lerp(from, to, p)!;
    final scale = 0.12 + 0.88 * p;
    final tp = TextPainter(
        text: TextSpan(
            text: text,
            style: style.copyWith(
              color: style.color!.withOpacity(((0.15 + 0.85 * p) * fade).clamp(0.0, 1.0)),
              shadows: [
                Shadow(color: _warm.withOpacity((0.55 * (1 - p * 0.5) * fade).clamp(0.0, 1.0)), blurRadius: 28),
                Shadow(color: Colors.black.withOpacity((0.8 * fade).clamp(0.0, 1.0)), blurRadius: 10, offset: const Offset(0, 2)),
              ],
            )),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center)
      ..layout(maxWidth: size.width - 32);
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.scale(scale);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  void _grain(Canvas canvas, Size size) {
    final r = math.Random((t * 600).floor());
    final light = <Offset>[], dark = <Offset>[];
    final count = (size.width * size.height / 300).clamp(600, 4500).toInt();
    for (var i = 0; i < count; i++) {
      final p = Offset(r.nextDouble() * size.width, r.nextDouble() * size.height);
      (i.isEven ? light : dark).add(p);
    }
    canvas.drawPoints(ui.PointMode.points, light, Paint()
      ..color = Colors.white.withOpacity(.035)
      ..strokeWidth = 1.2);
    canvas.drawPoints(ui.PointMode.points, dark, Paint()
      ..color = Colors.black.withOpacity(.18)
      ..strokeWidth = 1.2);
    final c = size.center(Offset.zero);
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(c, size.longestSide * 0.62, [Colors.transparent, Colors.black.withOpacity(.7)], const [0.5, 1]));
  }

  @override
  bool shouldRepaint(_IntroPainter old) => old.t != t;
}
