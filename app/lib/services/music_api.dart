import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'api.dart';

/// Venue music suggestions (supabase/migrations/20261020000039_venue_music.sql).
/// Search goes to Deezer: straight from the phone, or through the music-search function on the web.
class MusicApi {
  MusicApi._();
  static final _db = Api.db;

  static List<Map<String, dynamic>> _rows(dynamic res) =>
      List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));

  /// [{kind, id, title, artist, cover, preview, link}]
  static Future<List<Map<String, dynamic>>> search(String q, {bool albums = false}) async {
    final type = albums ? 'album' : 'track';
    if (q.trim().length < 2) return [];
    if (kIsWeb) {
      final res = await _db.functions.invoke('music-search', body: {'q': q, 'type': type});
      final data = Map<String, dynamic>.from((res.data as Map?) ?? const {});
      if (data['error'] != null) throw Exception(data['error']);
      return _rows(data['results'] ?? const []);
    }
    final r = await http.get(Uri.parse('https://api.deezer.com/search/$type?q=${Uri.encodeQueryComponent(q.trim())}&limit=15'));
    final data = (jsonDecode(r.body) as Map)['data'] as List? ?? const [];
    return [
      for (final d in data.cast<Map>())
        {
          'kind': type,
          'id': d['id'],
          'title': d['title'],
          'artist': (d['artist'] as Map?)?['name'] ?? '',
          'cover': albums ? d['cover_medium'] : (d['album'] as Map?)?['cover_medium'],
          'preview': albums ? null : ((d['preview'] as String?)?.isEmpty ?? true ? null : d['preview']),
          'link': d['link'],
        }
    ];
  }

  /// A fresh 30-second clip (Deezer's preview links expire after a while).
  static Future<String?> preview(int id, {bool album = false}) async {
    final type = album ? 'album' : 'track';
    if (kIsWeb) {
      final res = await _db.functions.invoke('music-search', body: {'preview': id, 'type': type});
      return (res.data as Map?)?['preview'] as String?;
    }
    final url = album ? 'https://api.deezer.com/album/$id/tracks?limit=1' : 'https://api.deezer.com/track/$id';
    final d = jsonDecode((await http.get(Uri.parse(url))).body) as Map;
    final list = d['data'] as List?;
    final p = album ? ((list == null || list.isEmpty) ? null : (list.first as Map)['preview']) : d['preview'];
    return (p as String?)?.isEmpty ?? true ? null : p as String;
  }

  static Future<Map<String, dynamic>> suggest(Map<String, dynamic> hit) async => Map<String, dynamic>.from(await _db.rpc(
        'suggest_song',
        params: {
          'p_kind': hit['kind'],
          'p_deezer_id': hit['id'],
          'p_title': hit['title'],
          'p_artist': hit['artist'],
          'p_cover': hit['cover'],
          'p_preview': hit['preview'],
          'p_link': hit['link'],
        },
      ) as Map);

  /// 1 up, -1 down, 0 take it back. Returns the new net score.
  static Future<int> vote(String songId, int vote) async =>
      (await _db.rpc('vote_song', params: {'p_song': songId, 'p_vote': vote}) as num).toInt();

  /// Tonight's ranked list where you're checked in (or, for staff, at [placeId]).
  static Future<List<Map<String, dynamic>>> tonight({String? placeId}) async =>
      _rows(await _db.rpc('tonight_songs', params: {'p_place': placeId}));

  static Future<int> left() async => (await _db.rpc('my_song_suggestions_left') as num).toInt();

  /// Staff: 'played', 'removed', or 'in'
  static Future<void> staffSet(String songId, String status) =>
      _db.rpc('staff_set_song', params: {'p_song': songId, 'p_status': status});
}
