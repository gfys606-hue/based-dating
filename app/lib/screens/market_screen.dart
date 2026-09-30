import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/social_api.dart';
import '../theme.dart';
import '../widgets/live_chat.dart';
import '../widgets/signed_photo.dart';
import '../widgets/ui.dart';

const marketCategories = {
  'vehicles': 'Vehicles',
  'tools': 'Tools',
  'outdoors': 'Outdoors',
  'home': 'Home',
  'electronics': 'Electronics',
  'clothing': 'Clothing',
  'sports': 'Sports',
  'other': 'Other',
};

const _conditions = {'new': 'New', 'like_new': 'Like new', 'used': 'Used', 'for_parts': 'For parts'};

/// Market: buy and sell locally. Message the seller; meet up to pay (no payments in-app yet).
class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});
  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  int _view = 0; // 0 browse, 1 my listings, 2 inbox
  String? _category;
  final _q = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _threads = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (_view == 2) {
        _threads = await SocialApi.myThreads();
      } else {
        _items = await SocialApi.listings(query: _q.text, category: _category, mine: _view == 1);
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _sell() async {
    final made = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _NewListingSheet(),
    );
    if (made == true) {
      setState(() => _view = 1);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Row(children: [
            Expanded(child: Text('Market', style: B.display(32))),
            FilledButton.icon(onPressed: _sell, icon: const Icon(Icons.add, size: 18), label: const Text('Sell')),
          ]),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Segmented(
              options: const ['Browse', 'Mine', 'Inbox'],
              index: _view,
              onChanged: (i) {
                setState(() => _view = i);
                _load();
              },
            ),
          ),
        ),
        if (_view == 0) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(hintText: 'Search the market', prefixIcon: Icon(Icons.search)),
              onSubmitted: (_) => _load(),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: PillChip(label: 'All', selected: _category == null, onTap: () { setState(() => _category = null); _load(); }),
                ),
                for (final c in marketCategories.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: PillChip(label: c.value, selected: _category == c.key, onTap: () { setState(() => _category = c.key); _load(); }),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Expanded(child: _loading ? const Center(child: CircularProgressIndicator()) : (_view == 2 ? _inbox() : _grid())),
      ]),
    );
  }

  Widget _grid() {
    if (_items.isEmpty) {
      return Center(
        child: Text(_view == 1 ? 'You haven\'t listed anything yet.' : 'Nothing here yet. Be the first to sell something.',
            style: TextStyle(color: B.muted)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: .72,
        ),
        itemCount: _items.length,
        itemBuilder: (context, i) => _tile(_items[i]),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> l) {
    final status = l['status'] as String;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listing: l)));
        _load();
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: l['photo_path'] == null
                  ? Container(
                      decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(10)),
                      child: Icon(Icons.image_outlined, color: B.muted),
                    )
                  : SignedPhoto(l['photo_path'] as String, radius: 16),
            ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: B.panel, borderRadius: BorderRadius.circular(6)),
                child: Text(money(l['price_cents'] as int),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ),
            if (status != 'active')
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: B.accent, borderRadius: BorderRadius.circular(6)),
                  child: Text(status.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        Text(l['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(l['distance_km'] == null ? (marketCategories[l['category']] ?? '') : '${l['distance_km']} km away',
            style: TextStyle(color: B.muted, fontSize: 12)),
      ]),
    );
  }

  Widget _inbox() {
    if (_threads.isEmpty) {
      return Center(child: Text('No conversations yet.', style: TextStyle(color: B.muted)));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        for (final t in _threads)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            leading: SizedBox(width: 52, height: 52, child: SignedPhoto(t['photo_path'] as String?, radius: 12)),
            title: Text(t['listing_title'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${t['i_am_seller'] == true ? 'Buyer' : 'Seller'}: ${t['other_name']} · ${t['last_message'] ?? 'No messages yet'}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text(money(t['price_cents'] as int), style: const TextStyle(fontWeight: FontWeight.w700)),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ThreadScreen(threadId: t['thread_id'] as String, title: t['listing_title'] as String),
              ));
              _load();
            },
          ),
      ],
    );
  }
}

/// One listing.
class ListingScreen extends StatelessWidget {
  const ListingScreen({super.key, required this.listing});
  final Map<String, dynamic> listing;

  @override
  Widget build(BuildContext context) {
    final l = listing;
    final mine = l['mine'] == true;
    return Scaffold(
      appBar: AppBar(title: Text(marketCategories[l['category']] ?? 'Listing')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        AspectRatio(
          aspectRatio: 1.1,
          child: l['photo_path'] == null
              ? Container(
                  decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(B.radius)),
                  child: Icon(Icons.image_outlined, size: 48, color: B.muted),
                )
              : SignedPhoto(l['photo_path'] as String, radius: B.radius),
        ),
        const SizedBox(height: 16),
        Text(money(l['price_cents'] as int), style: B.display(30)),
        const SizedBox(height: 4),
        Text(l['title'] as String, style: B.heading(20)),
        const SizedBox(height: 6),
        Text(
          [
            _conditions[l['condition']] ?? '',
            if (l['distance_km'] != null) '${l['distance_km']} km away',
            if (!mine) 'Sold by ${l['seller_name']}',
          ].join(' · '),
          style: TextStyle(color: B.muted),
        ),
        if (l['description'] != null) ...[
          const SizedBox(height: 14),
          Text(l['description'] as String, style: TextStyle(fontSize: 15, height: 1.45, color: B.ink2)),
        ],
        const SizedBox(height: 24),
        if (mine) ...[
          if (l['status'] == 'active')
            FilledButton(
              onPressed: () async {
                await SocialApi.setListingStatus(l['listing_id'] as String, 'sold');
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Mark as sold'),
            ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await SocialApi.setListingStatus(l['listing_id'] as String, 'removed');
              if (context.mounted) Navigator.pop(context);
            },
            child: Text('Remove listing', style: TextStyle(color: B.urgent)),
          ),
        ] else
          FilledButton.icon(
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Message seller'),
            onPressed: () async {
              try {
                final id = await SocialApi.messageSeller(l['listing_id'] as String);
                if (context.mounted) {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ThreadScreen(threadId: id, title: l['title'] as String)));
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This listing is no longer available.')));
                }
              }
            },
          ),
        const SizedBox(height: 12),
        Text('Meet in a public place and pay in person. Never send money before you see the item.',
            textAlign: TextAlign.center, style: TextStyle(color: B.muted, fontSize: 12)),
      ]),
    );
  }
}

/// Buyer ↔ seller chat about one listing.
class ThreadScreen extends StatelessWidget {
  const ThreadScreen({super.key, required this.threadId, required this.title});
  final String threadId;
  final String title;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: LiveChat(
          stream: SocialApi.threadMessages(threadId),
          onSend: (b) => SocialApi.sendThreadMessage(threadId, b),
          hint: 'Ask about it or arrange a time',
        ),
      );
}

class _NewListingSheet extends StatefulWidget {
  const _NewListingSheet();
  @override
  State<_NewListingSheet> createState() => _NewListingSheetState();
}

class _NewListingSheetState extends State<_NewListingSheet> {
  final _title = TextEditingController();
  final _price = TextEditingController();
  final _desc = TextEditingController();
  String _category = 'other';
  String _condition = 'used';
  String? _photo;
  bool _busy = false;
  String? _error;

  Future<void> _pickPhoto() async {
    final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600);
    if (img == null) return;
    setState(() => _busy = true);
    try {
      final path = await SocialApi.uploadListingPhoto(await img.readAsBytes());
      setState(() => _photo = path);
    } catch (_) {
      setState(() => _error = 'Photo upload failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _post() async {
    final price = double.tryParse(_price.text.replaceAll(RegExp(r'[^0-9.]'), ''));
    if (_title.text.trim().isEmpty || price == null) {
      setState(() => _error = 'Add a title and a price (0 for free).');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await SocialApi.createListing(
        title: _title.text.trim(),
        priceCents: (price * 100).round(),
        category: _category,
        condition: _condition,
        description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        photoPath: _photo,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      setState(() { _busy = false; _error = 'Couldn\'t post it. Try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Sell something', style: B.heading(22)),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _busy ? null : _pickPhoto,
            child: SizedBox(
              height: 140,
              child: _photo == null
                  ? Container(
                      decoration: BoxDecoration(color: B.fill, borderRadius: BorderRadius.circular(10)),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.add_a_photo_outlined, color: B.muted),
                        SizedBox(height: 6),
                        Text('Add a photo', style: TextStyle(color: B.muted)),
                      ]),
                    )
                  : SignedPhoto(_photo, radius: 16),
            ),
          ),
          const SizedBox(height: 10),
          TextField(controller: _title, decoration: const InputDecoration(hintText: 'What are you selling?')),
          const SizedBox(height: 10),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(hintText: 'Price', prefixText: '\$ '),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [for (final c in marketCategories.entries) DropdownMenuItem(value: c.key, child: Text(c.value))],
            onChanged: (v) => setState(() => _category = v ?? 'other'),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, children: [
            for (final c in _conditions.entries)
              ChoiceChip(label: Text(c.value), selected: _condition == c.key, onSelected: (_) => setState(() => _condition = c.key)),
          ]),
          const SizedBox(height: 10),
          TextField(controller: _desc, maxLines: 3, decoration: const InputDecoration(hintText: 'Details (optional)')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: B.urgent))),
          const SizedBox(height: 14),
          FilledButton(onPressed: _busy ? null : _post, child: Text(_busy ? 'Working…' : 'Post listing')),
        ]),
      ),
    );
  }
}
