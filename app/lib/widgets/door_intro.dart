import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import 'door_intro_plate.dart';

/// The opening (about 11 seconds, tap to skip), built from rendered images
/// (tools/intro_render): a bare bulb flickers on over a dark hallway, light leaks
/// under the door at the end, a shadow crosses behind it, the door cracks open,
/// holds, then swings wide onto a stairwell going down. "The Door" rises out of
/// the stairwell, then "is not for everyone.", and you walk through and down.
/// Plays once each time the app is opened.
class DoorIntro extends StatefulWidget {
  const DoorIntro({super.key, required this.child});
  final Widget child;

  static bool _played = false; // once per launch (survives light/dark rebuilds)

  @override
  State<DoorIntro> createState() => _DoorIntroState();
}

class _Imgs {
  _Imgs(this.closed, this.open, this.stairs);
  final ui.Image closed, open, stairs;
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
      final r = await Future.wait([_img('hall_closed.jpg'), _img('hall_open.jpg'), _img('stairs.jpg')])
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      setState(() => _imgs = _Imgs(r[0], r[1], r[2]));
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

/// The bulb catching: off, a couple of stutters, then on with a faint hum. Dips when the door cracks.
double _bulb(double t) {
  if (t < 0.035) return 0;
  if (t < 0.045) return 0.8;
  if (t < 0.058) return 0.06;
  if (t < 0.066) return 0.6;
  if (t < 0.076) return 0.18;
  final hum = 0.95 + 0.05 * math.sin(t * 300) * math.sin(t * 41);
  final dip = (t > 0.36 && t < 0.375) ? 0.55 : 1.0;
  return math.min(1.0, _seg(t, 0.076, 0.11)) * hum * dip;
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

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bulb = _bulb(t);
    final open = t < 0.48 ? 0.07 * _seg(t, 0.36, 0.41, Curves.easeOut) : 0.07 + 0.93 * _seg(t, 0.48, 0.62, Curves.easeInOutCubic);
    final shadowPass = _seg(t, 0.24, 0.33, Curves.easeInOut);
    final under = 0.55 + 0.35 * math.sin(shadowPass * math.pi);
    final walk = _seg(t, 0.86, 0.97, Curves.easeInCubic);
    final approach = 1 + 0.18 * _seg(t, 0.0, 0.58, Curves.easeInOut);
    final dolly = approach * (1 + 3.2 * walk);
    final toStairs = _seg(t, 0.90, 0.955, Curves.easeInOut);
    final black = _seg(t, 0.955, 1.0);

    // Fit the square hallway images: fill the height (portrait crops the sides);
    // on wide screens grow until it's at least 60% of the width.
    final s = math.max(h, w * 0.6);
    final k = s / _size;
    final doorC = _doorway.center;
    final base = Offset(w / 2 - doorC.dx * k, h * 0.44 - doorC.dy * k); // doorway a little above the middle
    final focus = base + doorC * k;
    Offset onScreen(Offset p, double z) => focus + (base + p * k - focus) * z;

    canvas.save();
    // camera: a slow walk toward the door, then through it
    canvas.translate(focus.dx, focus.dy);
    canvas.scale(dolly);
    canvas.translate(-focus.dx, -focus.dy);
    canvas.translate(base.dx, base.dy);
    canvas.scale(k);

    const plate = Rect.fromLTWH(0, 0, _size, _size);
    final q = Paint()..filterQuality = FilterQuality.medium;

    // 1. the hallway with the door closed, 2. the stairwell's light spilling in as it opens
    canvas.drawImageRect(imgs.closed, plate, plate, q);
    if (open > 0) {
      canvas.drawImageRect(imgs.open, plate, plate, Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withOpacity(open.clamp(0.0, 1.0)));
      canvas.save();
      canvas.clipRect(_doorway);
      canvas.drawImageRect(imgs.open, plate, plate, q);
      canvas.restore();
    }
    // the bulb's flicker darkens what it lights (the stairwell keeps its own light)
    final dim = (1 - bulb) * (1 - open * 0.6);
    if (dim > 0) canvas.drawRect(plate.inflate(4), Paint()..color = Colors.black.withOpacity(dim.clamp(0.0, 1.0)));

    // 3. light leaking under the closed door, with a shadow crossing behind it
    final df = _door;
    if (open < 1) {
      const n = 30;
      for (var i = 0; i < n; i++) {
        final mid = (i + .5) / n;
        final sx = -0.3 + 1.6 * shadowPass;
        final shade = (shadowPass > 0 && shadowPass < 1) ? 1 - 0.9 * math.exp(-math.pow((mid - sx) / 0.14, 2)) : 1.0;
        final x0 = df.left + df.width * i / n, x1 = df.left + df.width * (i + 1) / n;
        canvas.drawRect(
            Rect.fromLTRB(x0, df.bottom - 2.5, x1, df.bottom + 3.0),
            Paint()
              ..color = _warm.withOpacity(((0.35 + 0.55 * under) * shade * (1 - open)).clamp(0.0, 1.0))
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      }
      canvas.drawOval(
          Rect.fromCenter(center: Offset(df.center.dx, df.bottom + 16), width: df.width * 1.6, height: 44),
          Paint()
            ..color = _warm.withOpacity((0.12 * under * (1 - open)).clamp(0.0, 1.0))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
    }

    // 4. the door: hinged on the left, swinging away from us in true perspective
    final angle = open * 1.40; // up to ~80°
    canvas.save();
    canvas.translate(df.left, df.center.dy);
    final m = Matrix4.identity()
      ..setEntry(3, 2, 1 / DoorPlate.focal)
      ..rotateY(-angle);
    canvas.transform(m.storage);
    final doorDst = Rect.fromLTWH(0, -df.height / 2, df.width, df.height);
    canvas.drawImageRect(imgs.closed, df, doorDst, q);
    // turning away from the bulb it falls into shadow; the flicker applies too
    final dark = (math.sin(angle) * 0.7 + dim * 0.9).clamp(0.0, 0.95);
    if (dark > 0) canvas.drawRect(doorDst, Paint()..color = Colors.black.withOpacity(dark));
    if (open > 0.02) {
      // its edge catches the light from below
      canvas.drawRect(Rect.fromLTWH(df.width - 2, -df.height / 2, 2, df.height),
          Paint()..color = _warm.withOpacity(0.45 * math.min(1, open * 5)));
    }
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

    // 5. through the doorway and down the stairs
    if (toStairs > 0) {
      final sz = math.max(w, h) * (1.0 + 0.25 * toStairs);
      final dst = Rect.fromCenter(center: Offset(w / 2, h / 2), width: sz, height: sz);
      canvas.drawImageRect(imgs.stairs, Rect.fromLTWH(0, 0, imgs.stairs.width.toDouble(), imgs.stairs.height.toDouble()), dst,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Colors.white.withOpacity(toStairs));
    }

    // 6. the words rise out of the stairwell once the door is open
    final textOut = 1 - _seg(t, 0.86, 0.90);
    final from = onScreen(_stairs, approach);
    final doorBottom = onScreen(Offset(0, df.bottom), approach).dy;
    final bigSize = math.min(76.0, w * 0.165);
    final finalY = math.min(h - pad.bottom - bigSize * 1.9, math.max(doorBottom + bigSize * 0.75, h * 0.72));
    _rise(canvas, size, 'The Door', big.copyWith(fontSize: bigSize, letterSpacing: 2, color: B.gold),
        _seg(t, 0.60, 0.74, Curves.easeOutCubic), from, Offset(w / 2, finalY), textOut);
    _rise(canvas, size, 'is not for everyone.', small.copyWith(fontSize: bigSize * 0.48, color: const Color(0xFFEDE3C8)),
        _seg(t, 0.68, 0.82, Curves.easeOutCubic), from, Offset(w / 2, finalY + bigSize * 0.92), textOut);

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
  void _rise(Canvas canvas, Size size, String text, TextStyle style, double p, Offset from, Offset to, double fade) {
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
