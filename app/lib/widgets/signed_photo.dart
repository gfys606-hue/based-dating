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
