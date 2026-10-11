import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';

/// The opening (about 11 seconds, tap to skip), made from two real photographs
/// (tools/intro_photo): an antique bookcase in lamplight, and a vaulted brick cellar.
/// The lamp comes up, one pale book tilts out like a lever, a seam of warm light traces the
/// shelves, the bookcase cracks open, holds, then swings wide. You walk through into the
/// cellar, and "The Door" rises out of the dark at the end of the arches, then
/// "is not for everyone." Plays once each time the app is opened.
class DoorIntro extends StatefulWidget {
  const DoorIntro({super.key, required this.child});
  final Widget child;

  static bool _played = false; // once per launch (survives light/dark rebuilds)

  @override
  State<DoorIntro> createState() => _DoorIntroState();
}

/// Where things are in the photos (pixels).
class _P {
  static const booksW = 802.0, booksH = 1280.0;
  static const door = Rect.fromLTRB(68, 0, 716, 1280); // the shelves between the two columns: the part that swings
  static const lever = Rect.fromLTRB(165, 178, 190, 312); // the pale vellum book
  static const anchor = Offset(392, 600); // what the camera walks toward (the doorway's middle)
  static const cellarW = 1280.0, cellarH = 848.0;
  static const vp = Offset(693, 500); // the far end of the arches
  static const focal = 1500.0; // perspective for things that turn, in bookcase pixels
}

class _Imgs {
  _Imgs(this.books, this.cellar);
  final ui.Image books, cellar;
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
      final r = await Future.wait([_img('photo_books.jpg'), _img('photo_cellar.jpg')]).timeout(const Duration(seconds: 6));
      if (!mounted) return;
      setState(() => _imgs = _Imgs(r[0], r[1]));
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

/// The lamp coming up, with a faint flicker; it dips for a moment when the case unlatches.
double _lamp(double t) {
  if (t < 0.02) return 0;
  final up = _seg(t, 0.02, 0.11, Curves.easeInOut);
  final flicker = 0.965 + 0.035 * math.sin(t * 230) * math.sin(t * 41);
  final dip = (t > 0.372 && t < 0.385) ? 0.7 : 1.0;
  return up * flicker * dip;
}

class _IntroPainter extends CustomPainter {
  _IntroPainter(this.imgs, this.t, {required this.pad, required this.big, required this.small, required this.hint});
  final _Imgs imgs;
  final double t;
  final EdgeInsets pad;
  final TextStyle big, small, hint;

  static const _warm = Color(0xFFFFAE52);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final lamp = _lamp(t);
    final lever = _seg(t, 0.14, 0.22, Curves.easeOutBack) * (1 - _seg(t, 0.36, 0.39));
    final seam = _seg(t, 0.25, 0.37, Curves.easeIn);
    final open = t < 0.46 ? 0.05 * _seg(t, 0.37, 0.42, Curves.easeOut) : 0.05 + 0.95 * _seg(t, 0.46, 0.62, Curves.easeInOutCubic);
    final approach = _seg(t, 0.0, 0.56, Curves.easeInOut);
    final walk = _seg(t, 0.56, 0.82, Curves.easeInOutCubic);
    final after = _seg(t, 0.80, 1.0, Curves.easeOut);
    final black = _seg(t, 0.955, 1.0);

    // The camera: a slow push toward the bookcase with a slight drift, then through the doorway.
    // the whole bookcase on a phone (columns and all, darkness above and below); top to bottom on wide screens
    final k0 = math.min(h * 1.04 / _P.booksH, w * 1.06 / _P.booksW);
    final z = (1 + 0.07 * approach) * (1 + 3.6 * walk * walk);
    final centre = Offset(w / 2, h * 0.5);
    final drift = Offset((8 - 16 * approach) * (1 - walk), -4 * approach) * (h / 800);
    Offset scr(Offset p) => centre + drift + (p - _P.anchor) * (k0 * z);
    final doorScreen = Rect.fromPoints(scr(_P.door.topLeft), scr(_P.door.bottomRight));
    final booksScreen = Rect.fromPoints(scr(Offset.zero), scr(const Offset(_P.booksW, _P.booksH)));
    final q = Paint()..filterQuality = FilterQuality.medium;

    // 1. behind the bookcase: the cellar. It sits much further away, so it grows much less as we walk in.
    if (open > 0) {
      canvas.save();
      if (walk < 1) canvas.clipRect(doorScreen);
      // big enough to fill the doorway now and the whole screen once we're through (screen pixels per photo pixel)
      final s0 = math.max(math.max(_P.booksH * k0 * 1.08, h * 1.12) / _P.cellarH, w * 1.08 / (2 * (_P.cellarW - _P.vp.dx)));
      final zc = math.pow(z, 0.30).toDouble() * (1 + 0.12 * after);
      final cc = centre + drift * 0.4 + Offset(0, -(h * 0.02) * walk);
      final cw = _P.cellarW * s0 * zc, ch = _P.cellarH * s0 * zc;
      final cr = Rect.fromLTWH(cc.dx - _P.vp.dx / _P.cellarW * cw, cc.dy - _P.vp.dy / _P.cellarH * ch, cw, ch);
      canvas.drawImageRect(imgs.cellar, Rect.fromLTWH(0, 0, _P.cellarW, _P.cellarH), cr, q);
      // it comes up out of black as the door opens
      final hide = (1 - math.min(1.0, open * 2.2)).clamp(0.0, 1.0).toDouble();
      if (hide > 0) canvas.drawRect(cr, Paint()..color = Colors.black.withOpacity(hide));
      canvas.restore();
    }

    // 2. the bookcase frame (the two columns), and the room's darkness before the lamp
    canvas.save();
    canvas.translate(centre.dx + drift.dx, centre.dy + drift.dy);
    canvas.scale(k0 * z);
    canvas.translate(-_P.anchor.dx, -_P.anchor.dy);
    final dim = (1 - lamp).clamp(0.0, 1.0);
    for (final r in [
      Rect.fromLTRB(0, 0, _P.door.left, _P.booksH),
      Rect.fromLTRB(_P.door.right, 0, _P.booksW, _P.booksH),
    ]) {
      canvas.drawImageRect(imgs.books, r, r, q);
      if (dim > 0) canvas.drawRect(r.inflate(0.5), Paint()..color = Colors.black.withOpacity(dim));
    }
    // light from the cellar catches the inside edges of the columns once it's open
    if (open > 0.02) {
      final a = (0.30 * math.min(1.0, open * 3)).clamp(0.0, 1.0);
      for (final left in [true, false]) {
        final x = left ? _P.door.left : _P.door.right;
        final r = Rect.fromLTRB(left ? x - 26 : x, 0, left ? x : x + 26, _P.booksH);
        canvas.drawRect(
            r,
            Paint()
              ..blendMode = BlendMode.plus
              ..shader = LinearGradient(
                      begin: left ? Alignment.centerRight : Alignment.centerLeft,
                      end: left ? Alignment.centerLeft : Alignment.centerRight,
                      colors: [_warm.withOpacity(a), _warm.withOpacity(0)])
                  .createShader(r));
      }
    }

    // 3. the shelves themselves: a solid case hinged on the left, swinging away in perspective
    final d = _P.door;
    final angle = open * 1.45; // up to ~83°
    const thick = 46.0; // the case's depth, in photo pixels
    canvas.save();
    canvas.translate(d.left, d.center.dy);
    final m = Matrix4.identity()
      ..setEntry(3, 2, 1 / _P.focal)
      ..rotateY(-angle);
    if (angle > 0.01) {
      // its free side: solid wood, turning into view
      canvas.save();
      final side = m.clone()
        ..translate(d.width, 0.0, 0.0)
        ..rotateY(-math.pi / 2);
      canvas.transform(side.storage);
      final sr = Rect.fromLTWH(0, -d.height / 2, thick, d.height);
      canvas.drawRect(
          sr,
          Paint()
            ..shader = LinearGradient(colors: [
              Color.lerp(const Color(0xFF2A190D), const Color(0xFF6B4426), math.min(1.0, open * 1.5))!,
              const Color(0xFF140C06),
            ]).createShader(sr));
      canvas.drawRect(Rect.fromLTWH(0, -d.height / 2, 3, d.height), Paint()..color = _warm.withOpacity(0.45 * math.min(1.0, open * 4)));
      canvas.restore();
    }
    canvas.transform(m.storage);
    final doorDst = Rect.fromLTWH(0, -d.height / 2, d.width, d.height);
    canvas.drawImageRect(imgs.books, d, doorDst, q);
    // the lever: the pale book tilts out from its shelf (drawn on the door, so it rides along)
    if (lever > 0) {
      final lb = _P.lever.shift(Offset(-d.left, -d.center.dy));
      canvas.drawRect(lb, Paint()..color = const Color(0xFF0A0604).withOpacity(0.9 * lever.clamp(0.0, 1.0)));
      canvas.save();
      canvas.translate(lb.center.dx, lb.bottom);
      final tilt = Matrix4.identity()
        ..setEntry(3, 2, 1 / _P.focal)
        ..rotateX(0.62 * lever);
      canvas.transform(tilt.storage);
      canvas.drawImageRect(imgs.books, _P.lever, Rect.fromLTWH(-lb.width / 2, -lb.height, lb.width, lb.height), q);
      // its top catches the lamp as it leans out
      canvas.drawRect(Rect.fromLTWH(-lb.width / 2, -lb.height, lb.width, 6),
          Paint()..color = const Color(0xFFFFE6C0).withOpacity(0.25 * lever.clamp(0.0, 1.0)));
      canvas.restore();
    }
    // turning away from the lamp it falls into shadow
    final dark = (math.sin(angle) * 0.75 + dim).clamp(0.0, 1.0);
    if (dark > 0) canvas.drawRect(doorDst, Paint()..color = Colors.black.withOpacity(dark));
    canvas.restore();

    // 4. a seam of warm light around the shelves before they move
    if (seam > 0 && open < 1) {
      final a = (seam * (1 - open)).clamp(0.0, 1.0);
      final path = Path()
        ..moveTo(d.left, d.bottom)
        ..lineTo(d.left, d.top)
        ..moveTo(d.right, d.top)
        ..lineTo(d.right, d.bottom);
      canvas.drawPath(
          path,
          Paint()
            ..color = _warm.withOpacity(0.8 * a)
            ..strokeWidth = 5
            ..style = PaintingStyle.stroke
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
      canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFFFFE2B0).withOpacity(0.6 * a)
            ..strokeWidth = 1.4
            ..style = PaintingStyle.stroke);
      // and spilling on the floor under it
      canvas.drawOval(Rect.fromCenter(center: Offset(d.center.dx, d.bottom), width: d.width * 1.2, height: 60),
          Paint()
            ..color = _warm.withOpacity(0.18 * a)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24));
    }
    // a blade of light down the latch side while it's only ajar
    if (open > 0.003 && open < 0.4) {
      final edgeX = d.left + d.width * math.cos(angle) / (1 + d.width * math.sin(angle) / _P.focal);
      canvas.drawRect(
          Rect.fromLTRB(edgeX, d.top, d.right, d.bottom),
          Paint()
            ..color = _warm.withOpacity((0.4 * (1 - open * 2.5)).clamp(0.0, 1.0))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }
    canvas.restore();

    // soft edges where the photo ends (wide screens)
    final feather = booksScreen.width * 0.12;
    if (walk < 1) {
      final fv = booksScreen.height * 0.08;
      for (final r in [
        [Rect.fromLTWH(booksScreen.left, booksScreen.top, feather, booksScreen.height), Alignment.centerLeft, Alignment.centerRight],
        [Rect.fromLTWH(booksScreen.right - feather, booksScreen.top, feather, booksScreen.height), Alignment.centerRight, Alignment.centerLeft],
        [Rect.fromLTWH(booksScreen.left, booksScreen.top, booksScreen.width, fv), Alignment.topCenter, Alignment.bottomCenter],
        [Rect.fromLTWH(booksScreen.left, booksScreen.bottom - fv, booksScreen.width, fv), Alignment.bottomCenter, Alignment.topCenter],
      ]) {
        final rect = r[0] as Rect;
        canvas.drawRect(
            rect.inflate(1),
            Paint()
              ..shader = LinearGradient(begin: r[1] as Alignment, end: r[2] as Alignment, colors: const [Colors.black, Colors.transparent])
                  .createShader(rect));
      }
    }

    // 5. the words rise out of the dark at the end of the arches
    final textOut = 1 - _seg(t, 0.93, 0.965);
    final from = centre + drift * 0.4;
    final bigSize = math.min(78.0, w * 0.165);
    final finalY = math.min(h - pad.bottom - bigSize * 2.0, h * 0.70);
    final rise = _seg(t, 0.60, 0.77, Curves.easeOutCubic);
    final second = _seg(t, 0.68, 0.81, Curves.easeOut);
    _rise(canvas, size, 'The Door', big.copyWith(fontSize: bigSize, letterSpacing: 2, color: B.gold), rise, rise,
        from, Offset(w / 2, finalY), textOut);
    _rise(canvas, size, 'is not for everyone.', small.copyWith(fontSize: bigSize * 0.48, color: const Color(0xFFEDE3C8)), rise,
        second, from + Offset(0, bigSize * 0.11), Offset(w / 2, finalY + bigSize * 0.92), textOut);

    // 6. film grain and a vignette
    _grain(canvas, size);

    // tap to skip
    final hintA = 0.30 * _seg(t, 0.05, 0.12) * (1 - _seg(t, 0.52, 0.57));
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

  /// A line of text that starts small and dim deep in the cellar and rises toward you.
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
                Shadow(color: Colors.black.withOpacity((0.85 * fade).clamp(0.0, 1.0)), blurRadius: 12, offset: const Offset(0, 2)),
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
      ..color = Colors.white.withOpacity(.03)
      ..strokeWidth = 1.2);
    canvas.drawPoints(ui.PointMode.points, dark, Paint()
      ..color = Colors.black.withOpacity(.16)
      ..strokeWidth = 1.2);
    final c = size.center(Offset.zero);
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(c, size.longestSide * 0.62, [Colors.transparent, Colors.black.withOpacity(.72)], const [0.45, 1]));
  }

  @override
  bool shouldRepaint(_IntroPainter old) => old.t != t;
}
