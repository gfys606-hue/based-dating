import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/places_api.dart';
import '../theme.dart';
import 'ui.dart';

/// A small OpenStreetMap with gold pins. [pins] = [{lat, lng, label}].
class PlaceMap extends StatelessWidget {
  const PlaceMap({super.key, required this.pins, this.height = 200, this.zoom = 15});
  final List<Map<String, dynamic>> pins;
  final double height;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    final pts = [for (final p in pins) LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble())];
    if (pts.isEmpty) return const SizedBox.shrink();
    final fit = pts.length > 1
        ? CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(40), maxZoom: 16)
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(B.radius),
      child: SizedBox(
        height: height,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: pts.first,
            initialZoom: zoom,
            initialCameraFit: fit,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.based.based_dating',
            ),
            MarkerLayer(markers: [
              for (var i = 0; i < pts.length; i++)
                Marker(
                  point: pts[i],
                  width: 140,
                  height: 58,
                  alignment: Alignment.topCenter,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (pins[i]['label'] != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: B.onGold, borderRadius: BorderRadius.circular(2)),
                        child: Text(pins[i]['label'] as String,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                    Icon(Icons.location_on, color: B.goldInk, size: 30),
                  ]),
                ),
            ]),
            RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
          ],
        ),
      ),
    );
  }
}

/// A "Directions" button that opens the phone's maps app.
class DirectionsButton extends StatelessWidget {
  const DirectionsButton({super.key, required this.lat, required this.lng, this.compact = false});
  final double lat;
  final double lng;
  final bool compact;
  @override
  Widget build(BuildContext context) => compact
      ? IconButton(
          tooltip: 'Directions',
          icon: Icon(Icons.directions_outlined, color: B.accentStrong),
          onPressed: () => PlacesApi.directions(lat, lng),
        )
      : OutlinedButton.icon(
          onPressed: () => PlacesApi.directions(lat, lng),
          icon: const Icon(Icons.directions_outlined, size: 18),
          label: const Text('DIRECTIONS'),
        );
}

/// Pick a venue: your saved spots first, or search OpenStreetMap.
/// Returns {place_id, name, address, lat, lng} or null.
Future<Map<String, dynamic>?> pickPlace(BuildContext context, {String title = 'Where?'}) =>
    showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PlacePicker(title: title),
    );

class _PlacePicker extends StatefulWidget {
  const _PlacePicker({required this.title});
  final String title;
  @override
  State<_PlacePicker> createState() => _PlacePickerState();
}

class _PlacePickerState extends State<_PlacePicker> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _saved = [];
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    PlacesApi.refreshMyLocation();
    PlacesApi.myPlaces().then((s) {
      if (mounted) setState(() => _saved = s);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    // OpenStreetMap asks apps to search at most once a second
    _debounce = Timer(const Duration(milliseconds: 900), () => _search(v));
  }

  Future<void> _search(String v) async {
    if (v.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await PlacesApi.search(v);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = e is String ? e : 'Search didn\'t work. Try again.');
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _pickResult(Map<String, dynamic> r) async {
    try {
      final id = await PlacesApi.upsert(r);
      if (mounted) Navigator.pop(context, {...r, 'place_id': id});
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn\'t save that place. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSaved = _q.text.trim().isEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(widget.title, style: B.heading(22)),
                const SizedBox(height: 10),
                TextField(
                  controller: _q,
                  autofocus: _saved.isEmpty,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search a bar, restaurant or address',
                    suffixIcon: _searching
                        ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                        : null,
                  ),
                  onChanged: (v) {
                    setState(() {});
                    _onChanged(v);
                  },
                  onSubmitted: _search,
                ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: B.urgent))),
              ]),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(10, 0, 10, 12), children: [
                if (showSaved && _saved.isNotEmpty) ...[
                  const Padding(padding: EdgeInsets.fromLTRB(8, 6, 8, 4), child: SectionLabel('Your spots')),
                  for (final s in _saved)
                    ListTile(
                      leading: Icon(Icons.local_bar_outlined, color: B.goldInk),
                      title: Text(s['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text([s['address'], if (s['distance_km'] != null) '${s['distance_km']} km'].whereType<String>().join(' · ')),
                      onTap: () => Navigator.pop(context, s),
                    ),
                ],
                for (final r in _results)
                  ListTile(
                    leading: Icon(Icons.place_outlined, color: B.accentStrong),
                    title: Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(r['address'] as String? ?? ''),
                    onTap: () => _pickResult(r),
                  ),
                if (!showSaved && !_searching && _results.isEmpty && _error == null)
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text('No places found yet. Try the venue name and the city.', style: TextStyle(color: B.muted)),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Text('Places from OpenStreetMap', style: TextStyle(fontSize: 11, color: Colors.grey)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
