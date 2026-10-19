import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/invites_api.dart';

final _n = NumberFormat.decimalPattern();

/// "Friday at 8:00 PM", or "Oct 30 at 8:00 PM" when it's more than a week out.
String dropWhen(String iso) {
  final at = DateTime.parse(iso).toLocal();
  final soon = at.difference(DateTime.now()).inDays < 6;
  return '${DateFormat(soon ? 'EEEE' : 'MMM d').format(at)} at ${DateFormat('h:mm a').format(at)}';
}

/// One line about a city's door: how full it is, or when the next spots drop.
String doorLine(Map<String, dynamic> d) {
  final name = d['name'] as String? ?? 'Your city';
  final cap = d['cap'] as int?;
  final left = d['spots_left'] as int?;
  final members = d['members'] as int? ?? 0;
  final drop = d['next_drop'] as Map?;
  final dropText = drop == null ? '' : ' · ${_n.format(drop['spots'])} spots drop ${dropWhen(drop['at'] as String)}';
  if (cap == null || left == null) return '$name is open.$dropText';
  if (left > 0) return '$name · ${_n.format(members)} of ${_n.format(cap)} members · ${_n.format(left)} ${left == 1 ? 'spot' : 'spots'} left$dropText';
  final waiting = d['waiting'] as int? ?? 0;
  return '$name is full · ${_n.format(cap)} members${waiting > 0 ? ' · ${_n.format(waiting)} waiting' : ''}$dropText';
}

/// The door line for the sign-in page and the website. Quietly shows nothing if it can't load.
class CityDoorLine extends StatefulWidget {
  const CityDoorLine({super.key, this.style});
  final TextStyle? style;
  @override
  State<CityDoorLine> createState() => _CityDoorLineState();
}

class _CityDoorLineState extends State<CityDoorLine> {
  Map<String, dynamic>? _d;

  @override
  void initState() {
    super.initState();
    InvitesApi.cityDoor().then((d) {
      if (mounted) setState(() => _d = d);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) return const SizedBox.shrink();
    return Text(doorLine(d), style: widget.style);
  }
}
