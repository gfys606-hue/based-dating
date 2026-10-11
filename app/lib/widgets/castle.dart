import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// The castle: every screen sits somewhere in the same lamplit vaults as the opening.
/// Each tab is its own spot along the brick corridors (You is the study with the bookcase);
/// switching tabs walks you there, and opening a page takes you down a stone staircase.
class Castle {
  Castle._();

  /// Which room the backdrop shows (the tab index; see [_views]).
  static final view = ValueNotifier<int>(0);

  /// The view used behind pages opened on top of a tab (the stairwell landing).
  static const landing = 100;

  static ui.Image? cellar, books;
  static final ready = ValueNotifier<bool>(false);

  static Future<void> load() async {
    try {
      Future<ui.Image> img(String n) async =>
          decodeImageFromList((await rootBundle.load('assets/intro/$n')).buffer.asUint8List());
      final r = await Future.wait([img('photo_cellar.jpg'), img('photo_books.jpg')]);
      cellar = r[0];
      books = r[1];
      ready.value = true;
    } catch (_) {} // no photos: plain colors, everything still works
  }
}

/// A spot in the castle: which photo, where the camera looks (fractions of the photo) and how close.
class _View {
  const _View(this.study, this.x, this.y, this.zoom);
  final bool study;
  final double x, y, zoom;
}

const _views = <int, _View>{
  0: _View(false, 0.54, 0.56, 1.00), // Home: the great vault, all the arches ahead
  1: _View(false, 0.50, 0.60, 1.35), // Discover
  2: _View(false, 0.28, 0.52, 1.55), // Talk: an alcove off to the left
  3: _View(true, 0.50, 0.42, 1.15), // You: the study, by the bookcase
  4: _View(false, 0.56, 0.60, 1.75), // Friends: further down
  5: _View(false, 0.22, 0.72, 1.45), // Spots: by the steps out
  6: _View(false, 0.62, 0.50, 2.05), // Herd
  7: _View(false, 0.54, 0.59, 2.50), // Search: the far end
  8: _View(false, 0.80, 0.62, 1.55), // Events
  9: _View(false, 0.38, 0.44, 1.85), // Market
  Castle.landing: _View(false, 0.50, 0.82, 1.65), // a landing on the stairs
};

_View _v(int i) => _views[i] ?? _views[i % 10] ?? _views[0]!;

/// The walls around whatever's on screen. Follows [Castle.view] unless [fixed] is given.
class CastleBackdrop extends StatefulWidget {
  const CastleBackdrop({super.key, this.fixed});
  final int? fixed;
  @override
  State<CastleBackdrop> createState() => _CastleBackdropState();
}

class _CastleBackdropState extends State<CastleBackdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _walk = AnimationController(vsync: this, duration: const Duration(milliseconds: 950));
  late _View _from = _v(widget.fixed ?? Castle.view.value);
  late _View _to = _from;

  @override
  void initState() {
    super.initState();
    _walk.value = 1;
    if (widget.fixed == null) Castle.view.addListener(_go);
    Castle.ready.addListener(_redraw);
  }

  void _redraw() => setState(() {});

  void _go() {
    final next = _v(Castle.view.value);
    if (identical(next, _to)) return;
    // start from wherever the camera is right now
    _from = _lerp(_from, _to, Curves.easeInOutCubic.transform(_walk.value));
    _to = next;
    _walk.forward(from: 0);
  }

  static _View _lerp(_View a, _View b, double t) => _View(t < 0.5 ? a.study : b.study,
      a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.zoom + (b.zoom - a.zoom) * t);

  @override
  void dispose() {
    Castle.view.removeListener(_go);
    Castle.ready.removeListener(_redraw);
    _walk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: _walk,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _WallsPainter(_from, _to, _walk.value, B.isDark),
          ),
        ),
      );
}

class _WallsPainter extends CustomPainter {
  _WallsPainter(this.from, this.to, this.p, this.dark);
  final _View from, to;
  final double p;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = B.bg);
    final t = Curves.easeInOutCubic.transform(p);
    // the room you're leaving until halfway, then the one you're walking into (the swap hides in the shadow)
    final changing = from.study != to.study;
    final cur = _CastleBackdropState._lerp(from, to, t);
    final img = (changing ? (p < 0.5 ? from.study : to.study) : to.study) ? Castle.books : Castle.cellar;
    if (img != null) {
      final iw = img.width.toDouble(), ih = img.height.toDouble();
      final s = math.max(w / iw, h / ih) * cur.zoom;
      // footsteps: a slight bob while walking
      final bob = math.sin(p * math.pi * 6) * 3.0 * math.sin(p * math.pi);
      var dx = w / 2 - cur.x * iw * s, dy = h / 2 - cur.y * ih * s + bob;
      dx = dx.clamp(math.min(w - iw * s, 0.0), 0.0).toDouble();
      dy = dy.clamp(math.min(h - ih * s, 0.0), 0.0).toDouble();
      final paint = Paint()..filterQuality = FilterQuality.low;
      if (!dark) {
        // parchment: the vaults as a faint old print
        paint.colorFilter = const ColorFilter.matrix([
          0.30, 0.50, 0.12, 0, 30,
          0.26, 0.44, 0.10, 0, 24,
          0.20, 0.34, 0.08, 0, 16,
          0, 0, 0, 1, 0,
        ]);
      }
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, iw, ih), Rect.fromLTWH(dx, dy, iw * s, ih * s), paint);
    }
    // shade: mostly shadow, deeper as you pass between rooms
    final dip = math.sin(p * math.pi) * (changing ? 0.55 : 0.28);
    final shade = dark ? (0.62 + dip * 0.38) : (0.84 + dip * 0.16);
    canvas.drawRect(Offset.zero & size, Paint()..color = (dark ? Colors.black : B.bg).withOpacity(shade.clamp(0.0, 1.0).toDouble()));
    // lamplight from above
    final lamp = Offset(w * 0.55, -h * 0.08);
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..blendMode = dark ? BlendMode.plus : BlendMode.multiply
          ..shader = ui.Gradient.radial(lamp, h * 0.95, [
            dark ? const Color(0x2EFFA850) : const Color(0x14FFDDAA),
            dark ? const Color(0x00FFA850) : const Color(0x00FFFFFF),
          ]));
    // shadows close in at the edges
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(Offset(w / 2, h * 0.45), math.max(w, h) * 0.75,
              [Colors.transparent, (dark ? Colors.black : const Color(0xFF6B4A2A)).withOpacity(dark ? 0.7 : 0.12)], const [0.5, 1]));
  }

  @override
  bool shouldRepaint(_WallsPainter o) => o.p != p || o.from != from || o.to != to || o.dark != dark;
}

/// Opening a page takes you down a stone staircase; going back climbs it.
class StairsTransitions extends PageTransitionsBuilder {
  const StairsTransitions();
  // long enough to see the steps go by (used by Flutter versions that let a builder set it)
  Duration get transitionDuration => const Duration(milliseconds: 650);
  Duration get reverseTransitionDuration => const Duration(milliseconds: 550);
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      _Stairs(first: route.isFirst, animation: animation, secondary: secondaryAnimation, child: child);
}

class _Stairs extends StatelessWidget {
  const _Stairs({required this.first, required this.animation, required this.secondary, required this.child});
  final bool first;
  final Animation<double> animation, secondary;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // pages opened on top get their own walls (the stairwell landing), so nothing shows through from below
    final page = first ? child : Stack(fit: StackFit.expand, children: [const CastleBackdrop(fixed: Castle.landing), child]);
    return AnimatedBuilder(
      animation: Listenable.merge([animation, secondary]),
      child: page,
      builder: (context, page) {
        final h = MediaQuery.sizeOf(context).height;
        final a = Curves.easeInOutCubic.transform(animation.value);
        final s = Curves.easeInOutCubic.transform(secondary.value);
        Widget out = page!;
        // this page heads up out of view (you're going down) and falls into shadow
        if (s > 0) {
          out = Stack(fit: StackFit.expand, children: [
            Transform.translate(offset: Offset(0, -h * 0.10 * s), child: out),
            IgnorePointer(child: ColoredBox(color: Colors.black.withOpacity((0.75 * s).clamp(0.0, 1.0).toDouble()))),
          ]);
        }
        // coming in: the steps go by, then the new room rises into place
        if (!first && a < 1) {
          final stairs = math.sin(a * math.pi);
          out = Stack(fit: StackFit.expand, children: [
            if (stairs > 0.01)
              IgnorePointer(
                child: Opacity(
                  opacity: stairs.clamp(0.0, 1.0).toDouble(),
                  child: CustomPaint(size: Size.infinite, painter: _StepsPainter(animation.value, B.isDark)),
                ),
              ),
            Opacity(
              opacity: ((a - 0.25) / 0.6).clamp(0.0, 1.0).toDouble(),
              child: Transform.translate(offset: Offset(0, h * 0.22 * (1 - a)), child: out),
            ),
          ]);
        }
        return out;
      },
    );
  }
}

/// A stone staircase going down into lamplight, textured with the vaults' own stone.
class _StepsPainter extends CustomPainter {
  _StepsPainter(this.p, this.dark);
  final double p;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = dark ? const Color(0xFF0B0705) : B.bg);
    final img = Castle.cellar;
    Paint stone(double light, {double scale = 0.55, double oy = 0.70}) {
      final pnt = Paint();
      if (img != null) {
        final m = Matrix4.identity()
          ..scale(scale, scale)
          ..translate(0.0, -img.height * oy);
        pnt.shader = ImageShader(img, TileMode.repeated, TileMode.repeated, m.storage);
        pnt.colorFilter = ColorFilter.mode(Colors.black.withOpacity((1 - light).clamp(0.0, 1.0).toDouble()), BlendMode.srcATop);
      } else {
        pnt.color = Color.lerp(Colors.black, const Color(0xFF6B5440), light)!;
      }
      return pnt;
    }

    // descending: the steps slide up toward the top of the screen as you go down
    final phase = (p * 2.2) % 1.0;
    final vx = w / 2, top = h * 0.10;
    double y(double d) => top + (h - top) / (1 + 0.55 * d);
    double half(double d) => w * 0.48 / (1 + 0.55 * d);
    // the walls: brick on both sides, darker with depth
    final wall = Path()
      ..moveTo(0, 0)
      ..lineTo(vx - half(9), y(9))
      ..lineTo(vx - half(-0.6), h * 1.2)
      ..lineTo(0, h * 1.2)
      ..close();
    final wallR = Path()
      ..moveTo(w, 0)
      ..lineTo(vx + half(9), y(9))
      ..lineTo(vx + half(-0.6), h * 1.2)
      ..lineTo(w, h * 1.2)
      ..close();
    canvas.drawPath(wall, stone(0.38, scale: 0.8, oy: 0.25));
    canvas.drawPath(wallR, stone(0.30, scale: 0.8, oy: 0.30));
    for (var k = 9; k >= -1; k--) {
      final d0 = k - phase, d1 = d0 + 0.62, d2 = d0 + 1;
      if (d0 < -1) continue;
      final fog = 1 / (1 + 0.35 * math.max(d0, 0));
      // tread (the flat part), lit from the lamp below
      final tread = Path()
        ..moveTo(vx - half(d0), y(d0))
        ..lineTo(vx + half(d0), y(d0))
        ..lineTo(vx + half(d1), y(d1))
        ..lineTo(vx - half(d1), y(d1))
        ..close();
      canvas.drawPath(tread, stone(0.62 * fog + 0.08));
      // riser (the step's face): in shadow
      final riser = Path()
        ..moveTo(vx - half(d1), y(d1))
        ..lineTo(vx + half(d1), y(d1))
        ..lineTo(vx + half(d2), y(d2))
        ..lineTo(vx - half(d2), y(d2))
        ..close();
      canvas.drawPath(riser, stone(0.22 * fog));
      // worn front edge catching the light
      canvas.drawLine(Offset(vx - half(d0), y(d0)), Offset(vx + half(d0), y(d0)),
          Paint()
            ..color = const Color(0xFFFFC27A).withOpacity(0.10 * fog)
            ..strokeWidth = 1.2);
    }
    // warm light down at the bottom of the stairs
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(Offset(vx, y(9)), h * 0.5, [const Color(0x55FFA040), const Color(0x00FFA040)]));
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(Offset(w / 2, h / 2), math.max(w, h) * 0.7,
              [Colors.transparent, Colors.black.withOpacity(dark ? 0.75 : 0.45)], const [0.45, 1]));
    if (!dark) canvas.drawRect(Offset.zero & size, Paint()..color = B.bg.withOpacity(0.45));
  }

  @override
  bool shouldRepaint(_StepsPainter o) => o.p != p || o.dark != dark;
}
