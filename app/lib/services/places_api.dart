import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// Venues (OpenStreetMap search), watering holes and "Here now"
/// (supabase/migrations/20261003000018_places_here_now.sql).
class PlacesApi {
  PlacesApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  static double? _lat, _lng;
  static DateTime? _lastFix;

  /// Update my location (used for distances only; never shown to anyone). At most every 10 minutes.
  static Future<void> refreshMyLocation() async {
    if (_lastFix != null && DateTime.now().difference(_lastFix!) < const Duration(minutes: 10)) return;
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 12)),
      );
      _lat = pos.latitude;
      _lng = pos.longitude;
      _lastFix = DateTime.now();
      await Api.updateProfile({'lat': pos.latitude, 'lng': pos.longitude});
    } catch (_) {}
  }

  /// Search OpenStreetMap for a venue, biased toward where I am.
  /// Returns [{osm_id, name, address, lat, lng}].
  static Future<List<Map<String, dynamic>>> search(String query) async {
    final q = query.trim();
    if (q.length < 2) return [];
    final params = <String, String>{
      'format': 'jsonv2',
      'q': q,
      'limit': '8',
      'addressdetails': '1',
    };
    if (_lat != null && _lng != null) {
      // Prefer results within ~40 km, but still allow farther ones
      params['viewbox'] = '${_lng! - .5},${_lat! + .35},${_lng! + .5},${_lat! - .35}';
    }
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final res = await http.get(uri, headers: {
      if (!kIsWeb) 'User-Agent': 'BasedSocial/1.0 (https://based-social.com)',
      'Accept-Language': 'en',
    });
    if (res.statusCode != 200) throw 'Search is busy. Try again in a moment.';
    final list = jsonDecode(res.body) as List;
    return [
      for (final r in list.cast<Map<String, dynamic>>())
        {
          'osm_id': '${r['osm_type']}/${r['osm_id']}',
          'name': _name(r),
          'address': _address(r),
          'lat': double.tryParse('${r['lat']}'),
          'lng': double.tryParse('${r['lon']}'),
          'kind': r['type'],
        }
    ].where((r) => r['lat'] != null && r['lng'] != null).toList();
  }

  /// Cities and towns anywhere (travel mode). Returns [{name, address, lat, lng}].
  static Future<List<Map<String, dynamic>>> searchCity(String query) async {
    final q = query.trim();
    if (q.length < 2) return [];
    final uri = Uri.https('nominatim.openstreetmap.org', '/search',
        {'format': 'jsonv2', 'q': q, 'limit': '6', 'featureType': 'settlement', 'addressdetails': '1'});
    final res = await http.get(uri, headers: {
      if (!kIsWeb) 'User-Agent': 'BasedSocial/1.0 (https://based-social.com)',
      'Accept-Language': 'en',
    });
    if (res.statusCode != 200) throw 'Search is busy. Try again in a moment.';
    return [
      for (final r in (jsonDecode(res.body) as List).cast<Map<String, dynamic>>())
        {
          'name': _name(r),
          'address': (r['display_name'] as String? ?? '').split(',').skip(1).map((e) => e.trim()).where((e) => e.isNotEmpty).take(2).join(', '),
          'lat': double.tryParse('${r['lat']}'),
          'lng': double.tryParse('${r['lon']}'),
        }
    ].where((r) => r['lat'] != null && r['lng'] != null).toList();
  }

  static String _name(Map<String, dynamic> r) {
    final n = (r['name'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n;
    return (r['display_name'] as String? ?? 'Place').split(',').first.trim();
  }

  static String _address(Map<String, dynamic> r) {
    final a = (r['address'] as Map?)?.cast<String, dynamic>() ?? const {};
    final street = [a['house_number'], a['road']].whereType<String>().join(' ');
    final area = a['neighbourhood'] ?? a['suburb'];
    final city = a['city'] ?? a['town'] ?? a['village'];
    final parts = [if (street.isNotEmpty) street, if (area != null) area, if (city != null) city].cast<String>();
    if (parts.isNotEmpty) return parts.join(', ');
    final d = (r['display_name'] as String? ?? '').split(',').map((e) => e.trim()).toList();
    return d.skip(1).take(3).join(', ');
  }

  /// Save a search result as a Based place (or reuse it). Returns the place id.
  static Future<String> upsert(Map<String, dynamic> r) async => await _db.rpc('upsert_place', params: {
        'p_osm_id': r['osm_id'],
        'p_name': r['name'],
        'p_address': r['address'],
        'p_lat': r['lat'],
        'p_lng': r['lng'],
      }) as String;

  static Future<void> save(String placeId, bool save) =>
      _db.rpc('save_place', params: {'p_place': placeId, 'p_save': save});

  static Future<List<Map<String, dynamic>>> myPlaces() async => _rows(await _db.rpc('get_my_places'));

  // ---------- Here now ----------
  static Future<void> checkIn(String placeId, {int hours = 3, String audience = 'inner', bool notify = false}) =>
      _db.rpc('check_in', params: {'p_place': placeId, 'p_hours': hours, 'p_audience': audience, 'p_notify': notify});
  static Future<void> checkOut() => _db.rpc('check_out');
  static Future<List<Map<String, dynamic>>> hereNow() async => _rows(await _db.rpc('get_here_now'));

  /// Open turn-by-turn directions in the phone's maps app (or Google Maps on the web).
  static Future<void> directions(double lat, double lng) => launchUrl(
        Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng'),
        mode: LaunchMode.externalApplication,
      );
}
