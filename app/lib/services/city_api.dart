import 'package:flutter/foundation.dart';

import 'api.dart';

/// Your city (supabase/migrations/20261006000029_cities.sql).
/// [current] updates everywhere it's shown (Home) as soon as you change it.
class CityApi {
  CityApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  /// {slug, name, region} of the city you're in
  static final current = ValueNotifier<Map<String, dynamic>?>(null);

  static Future<Map<String, dynamic>?> mine() async {
    final r = await _db.rpc('my_city');
    final m = r == null ? null : Map<String, dynamic>.from(r as Map);
    current.value = m;
    return m;
  }

  /// Cities you can pick right now
  static Future<List<Map<String, dynamic>>> open() async => _rows(await _db.rpc('get_cities'));

  static Future<void> set(String slug) async {
    final r = await _db.rpc('set_city', params: {'p_city': slug});
    current.value = r == null ? null : Map<String, dynamic>.from(r as Map);
  }

  // ---------- admin ----------
  static Future<List<Map<String, dynamic>>> all() async => _rows(await _db.rpc('admin_cities'));
  static Future<void> add(String name, {String? region}) =>
      _db.rpc('admin_add_city', params: {'p_name': name, 'p_region': region});
  static Future<void> setOpen(String slug, bool open) =>
      _db.rpc('admin_set_city_active', params: {'p_city': slug, 'p_active': open});
}
