import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/diagnostics.dart';
import '../theme.dart';

/// Tells Android testers a newer build is out, and updates them in place —
/// no "uninstall the old one first" (every build.yml build is signed with the
/// same upload key, so Android treats a newer APK as an update, not a new app).
/// Checked against https://based-social.com/test/build.json (same file the
/// download page reads). Web and iPhone users never see this: the web app
/// updates itself, and iPhone has no separate APK to install.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});
  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  static const _dismissedKey = 'update_banner_dismissed_build';
  int? _latest;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // Only Android test builds update this way; web updates itself and there's
    // no APK on iPhone. A local/dev run has no build number to compare.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final current = int.tryParse(Diagnostics.build);
    if (current == null) return;
    try {
      final r = await http.get(Uri.parse('https://based-social.com/test/build.json')).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final latest = (jsonDecode(r.body) as Map)['build'] as int?;
      if (latest == null || latest <= current) return;
      final prefs = await SharedPreferences.getInstance();
      final dismissedFor = prefs.getInt(_dismissedKey);
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _dismissed = dismissedFor != null && dismissedFor >= latest;
      });
    } catch (_) {} // no network, or the page is down — just stay quiet
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_dismissedKey, _latest!);
  }

  @override
  Widget build(BuildContext context) {
    if (_latest == null || _dismissed) return const SizedBox.shrink();
    return Material(
      color: B.gold,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(children: [
            const Icon(Icons.system_update_alt, size: 20, color: B.onGold),
            const SizedBox(width: 10),
            Expanded(
              child: Text('An update is ready (build $_latest). Tap to install — your account and matches stay put.',
                  style: const TextStyle(color: B.onGold, fontWeight: FontWeight.w600, fontSize: 13.5)),
            ),
            TextButton(
              onPressed: () => launchUrl(Uri.parse('https://based-social.com/test/based-test.apk'), mode: LaunchMode.externalApplication),
              style: TextButton.styleFrom(foregroundColor: B.onGold, backgroundColor: Colors.black.withOpacity(.12)),
              child: const Text('Update', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            IconButton(
              onPressed: _dismiss,
              icon: const Icon(Icons.close, size: 18, color: B.onGold),
              tooltip: 'Not now',
              splashRadius: 18,
            ),
          ]),
        ),
      ),
    );
  }
}
