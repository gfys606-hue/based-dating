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

  /// Your feed, your rules: what you've steered, and a reset.
  Future<void> _tune() async {
    Map<String, dynamic> prefs;
    try {
      prefs = await Api.feedPrefs();
    } catch (_) {
      prefs = {};
    }
    if (!mounted) return;
    String label(int w) => switch (w) { -2 => 'Hidden', -1 => 'Less', 1 => 'More', 2 => 'Lots more', _ => '' };
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final topics = List<Map<String, dynamic>>.from((prefs['topics'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
          final people = List<Map<String, dynamic>>.from((prefs['people'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .75),
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(20), children: [
                Text('Your feed, your rules', style: B.heading(24)),
                const SizedBox(height: 4),
                Text('Tap "Why this?" on any post to steer it. Everything you\'ve told it is here, and you can start over anytime.',
                    style: TextStyle(color: B.muted, fontSize: 13, height: 1.4)),
                const SizedBox(height: 12),
                if (topics.isEmpty && people.isEmpty) Text('Nothing steered yet.', style: TextStyle(color: B.ink2)),
                if (topics.isNotEmpty) const SectionLabel('Topics'),
                for (final t in topics)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t['name'] as String),
                    subtitle: Text(label(t['weight'] as int)),
                    trailing: TextButton(
                      onPressed: () async {
                        await Api.setTopicPref(t['topic_id'] as int, 0);
                        set(() => (prefs['topics'] as List).removeWhere((x) => (x as Map)['topic_id'] == t['topic_id']));
                      },
                      child: const Text('UNDO'),
                    ),
                  ),
                if (people.isNotEmpty) const SectionLabel('People'),
                for (final p in people)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(p['name'] as String),
                    subtitle: Text(label(p['weight'] as int)),
                    trailing: TextButton(
                      onPressed: () async {
                        await Api.setAuthorPref(p['user_id'] as String, 0);
                        set(() => (prefs['people'] as List).removeWhere((x) => (x as Map)['user_id'] == p['user_id']));
                      },
                      child: const Text('UNDO'),
                    ),
                  ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Api.resetFeed();
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('RESET MY FEED'),
                ),
              ]),
            ),
          );
        },
      ),
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fresh start. Your feed is back to your interests and who you know.')));
    }
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
      backgroundColor: B.card,
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
            Text('Contact info, links and social handles are blocked in posts.', style: TextStyle(fontSize: 12, color: B.muted)),
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
              style: FilledButton.styleFrom(backgroundColor: B.panel, minimumSize: const Size(0, 40)),
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('Post'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _tune,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Tune'),
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
                return ListView(children: [
                  SizedBox(height: 120),
                  Center(child: Text('Nothing this close yet. Widen the distance or post something.', style: TextStyle(color: B.muted))),
                ]);
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, B.navClearance),
                itemCount: posts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _PostCard(post: posts[i], onSteered: _refresh),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

class _PostCard extends StatefulWidget {
  const _PostCard({required this.post, this.onSteered});
  final Map<String, dynamic> post;
  final VoidCallback? onSteered;
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
            Text('${p['topic']}${km == null ? '' : ' · $km km'}', style: TextStyle(fontSize: 12, color: B.muted)),
          ]),
        ),
        if (p['why'] != null)
          InkWell(
            onTap: () => _why(context),
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Icon(Icons.info_outline, size: 13, color: B.muted),
                const SizedBox(width: 4),
                Flexible(child: Text('${p['why']} · Why this?', style: TextStyle(fontSize: 12, color: B.muted))),
              ]),
            ),
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
            Text('${p['like_count']} likes · only you see this', style: TextStyle(fontSize: 13, color: B.muted)),
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

  /// Why this post is here, and buttons to steer: more/less of the topic, less from this person.
  Future<void> _why(BuildContext context) async {
    final p = widget.post;
    final mine = p['author_id'] == Api.me;
    final topicId = p['topic_id'] as int?;
    final done = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Why you\'re seeing this', style: B.heading(22)),
              const SizedBox(height: 4),
              Text('${p['why']}.', style: TextStyle(color: B.ink2, fontSize: 15)),
            ]),
          ),
          if (topicId != null) ...[
            ListTile(leading: const Icon(Icons.add_circle_outline), title: Text('More ${p['topic']}'), onTap: () => Navigator.pop(ctx, 'topic+')),
            ListTile(leading: const Icon(Icons.remove_circle_outline), title: Text('Less ${p['topic']}'), onTap: () => Navigator.pop(ctx, 'topic-')),
            ListTile(leading: const Icon(Icons.visibility_off_outlined), title: Text('Hide ${p['topic']}'), onTap: () => Navigator.pop(ctx, 'topicx')),
          ],
          if (!mine) ...[
            ListTile(leading: const Icon(Icons.person_add_alt), title: Text('More from ${p['author_name']}'), onTap: () => Navigator.pop(ctx, 'author+')),
            ListTile(leading: const Icon(Icons.person_remove_alt_1_outlined), title: Text('Less from ${p['author_name']}'), onTap: () => Navigator.pop(ctx, 'author-')),
          ],
        ]),
      ),
    );
    if (done == null) return;
    try {
      switch (done) {
        case 'topic+':
          await Api.setTopicPref(topicId!, 1);
        case 'topic-':
          await Api.setTopicPref(topicId!, -1);
        case 'topicx':
          await Api.setTopicPref(topicId!, -2);
        case 'author+':
          await Api.setAuthorPref(p['author_id'] as String, 1);
        case 'author-':
          await Api.setAuthorPref(p['author_id'] as String, -1);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Got it. Change it anytime under Tune.')));
      }
      widget.onSteered?.call();
    } catch (_) {}
  }

  Future<void> _openComments(BuildContext context, String postId) async {
    final ctrl = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: B.card,
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
