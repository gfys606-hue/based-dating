import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'profile_view_screen.dart';

/// Posts (the interest feed), shown inside Discover. Open to everyone, with a
/// distance filter. No follower counts; like counts are only shown to the author.
class PostsView extends StatefulWidget {
  const PostsView({super.key});
  @override
  State<PostsView> createState() => _PostsViewState();
}

class _PostsViewState extends State<PostsView> {
  static const _ranges = ['local', 'region', 'province', 'country', 'global'];
  static const _labels = ['Local', 'Region', 'Province', 'Country', 'Global'];
  int _range = 4;
  late Future<List<Map<String, dynamic>>> _posts = _load();

  Future<List<Map<String, dynamic>>> _load() => Api.feed(range: _ranges[_range]);

  Future<void> _refresh() async => setState(() => _posts = _load());

  Future<void> _setRange(int i) async {
    setState(() => _range = i);
    await Api.updateProfile({'feed_range': _ranges[i]});
    _refresh();
  }

  Future<void> _compose() async {
    final topics = await Api.topics();
    if (!mounted) return;
    final body = TextEditingController();
    int? topic;
    String kind = 'take';
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('New post', style: B.heading(20)),
            const SizedBox(height: 12),
            Row(children: [
              PillChip(label: 'Take', selected: kind == 'take', onTap: () => setSheet(() => kind = 'take')),
              const SizedBox(width: 6),
              PillChip(label: 'Question', selected: kind == 'question', onTap: () => setSheet(() => kind = 'question')),
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: topic,
              hint: const Text('Topic'),
              items: [for (final t in topics) DropdownMenuItem(value: t['id'] as int, child: Text(t['name'] as String))],
              onChanged: (v) => setSheet(() => topic = v),
            ),
            const SizedBox(height: 10),
            TextField(controller: body, maxLength: 500, maxLines: 4, decoration: const InputDecoration(hintText: 'Say what you actually think')),
            const Text('Contact info, links and social handles are blocked in posts.', style: TextStyle(fontSize: 12, color: B.muted)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                if (topic == null || body.text.trim().isEmpty) return;
                await Api.post(topicId: topic!, kind: kind, body: body.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Post'),
            ),
          ]),
        ),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          children: [
            FilledButton.icon(
              onPressed: _compose,
              style: FilledButton.styleFrom(backgroundColor: B.ink, minimumSize: const Size(0, 40)),
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('Post'),
            ),
            const SizedBox(width: 10),
            for (var i = 0; i < _labels.length; i++) ...[
              Center(child: PillChip(label: _labels[i], selected: i == _range, onTap: () => _setRange(i))),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder(
            future: _posts,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
              final posts = snap.data ?? [];
              if (posts.isEmpty) {
                return ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: Text('Nothing this close yet. Widen the distance or post something.', style: TextStyle(color: B.muted))),
                ]);
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, B.navClearance),
                itemCount: posts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _PostCard(post: posts[i]),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

class _PostCard extends StatefulWidget {
  const _PostCard({required this.post});
  final Map<String, dynamic> post;
  @override
  State<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<_PostCard> {
  late bool _liked = widget.post['my_reaction'] == true;
  late bool _saved = widget.post['my_save'] == true;

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final km = p['distance_km'];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: B.cardBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ProfileViewScreen(userId: p['author_id'] as String),
          )),
          child: Row(children: [
            Avatar(path: p['author_photo'] as String?, size: 34),
            const SizedBox(width: 10),
            Expanded(child: Text(p['author_name'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text('${p['topic']}${km == null ? '' : ' · $km km'}', style: const TextStyle(fontSize: 12, color: B.muted)),
          ]),
        ),
        const SizedBox(height: 8),
        if (p['kind'] == 'question') const SectionLabel('Question'),
        Text(p['body'] as String? ?? '', style: const TextStyle(fontSize: 15, height: 1.45)),
        const SizedBox(height: 6),
        Row(children: [
          PillChip(
            label: _liked ? 'Liked' : 'Like',
            selected: _liked,
            onTap: () { setState(() => _liked = !_liked); Api.react(p['post_id'] as String, _liked); },
          ),
          const SizedBox(width: 8),
          if (p['like_count'] != null)
            Text('${p['like_count']} likes · only you see this', style: const TextStyle(fontSize: 13, color: B.muted)),
          const Spacer(),
          IconButton(
            tooltip: 'Comments',
            icon: const Icon(Icons.mode_comment_outlined),
            onPressed: () => _openComments(context, p['post_id'] as String),
          ),
          Text('${p['comment_count']}'),
          IconButton(
            tooltip: _saved ? 'Saved' : 'Save',
            icon: Icon(_saved ? Icons.bookmark : Icons.bookmark_border),
            onPressed: () { setState(() => _saved = !_saved); Api.save(p['post_id'] as String, _saved); },
          ),
        ]),
      ]),
    );
  }

  Future<void> _openComments(BuildContext context, String postId) async {
    final ctrl = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: FutureBuilder(
          future: Api.comments(postId),
          builder: (ctx, snap) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Comments', style: B.heading(20)),
            for (final c in snap.data ?? const <Map<String, dynamic>>[])
              ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(c['body'] as String)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              decoration: InputDecoration(
                hintText: 'Disagree respectfully',
                suffixIcon: IconButton(
                  tooltip: 'Send',
                  icon: const Icon(Icons.send),
                  onPressed: () async {
                    if (ctrl.text.trim().isEmpty) return;
                    await Api.comment(postId, ctrl.text.trim());
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
