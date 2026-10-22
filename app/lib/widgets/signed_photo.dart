import 'package:flutter/material.dart';

import '../services/api.dart';

/// Displays a photo from the private "photos" bucket via a short-lived signed URL.
class SignedPhoto extends StatelessWidget {
  const SignedPhoto(this.path, {super.key, this.fit = BoxFit.cover, this.radius = 0});
  final String? path;
  final BoxFit fit;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (path == null) return _placeholder(context);
    if (path!.startsWith('test:')) return _TestPhoto(path!, radius: radius);
    return FutureBuilder<String>(
      future: Api.photoUrl(path!),
      builder: (context, snap) {
        if (!snap.hasData) return _placeholder(context);
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.network(snap.data!, fit: fit, width: double.infinity, height: double.infinity),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

/// Test profiles (is_test) have no real photos: draw a warm card with a TEST mark instead.
class _TestPhoto extends StatelessWidget {
  const _TestPhoto(this.path, {required this.radius});
  final String path;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final h = path.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
    final hue = (h % 360).toDouble();
    final top = HSLColor.fromAHSL(1, hue, .35, .42).toColor();
    final bottom = HSLColor.fromAHSL(1, (hue + 40) % 360, .40, .22).toColor();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [top, bottom])),
        child: LayoutBuilder(
          builder: (context, c) => Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.person, color: Colors.white70, size: c.maxWidth * .45),
              if (c.maxWidth > 70)
                const Text('TEST', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 2)),
            ]),
          ),
        ),
      ),
    );
  }
}
