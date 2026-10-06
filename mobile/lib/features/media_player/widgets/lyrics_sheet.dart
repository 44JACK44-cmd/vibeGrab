import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/lyrics_service.dart';
import '../../../services/media_engine.dart';

/// Bottom sheet with the song lyrics: synced lines auto-scroll and highlight
/// with the playback position, plain text otherwise.
class LyricsSheet extends StatefulWidget {
  const LyricsSheet({super.key});

  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  Lyrics? _lyrics;
  bool _loading = true;
  String _title = '';
  String _artist = '';
  final ScrollController _scroll = ScrollController();
  int _lastIndex = -2;

  @override
  void initState() {
    super.initState();
    final engine = context.read<MediaEngine>();
    _title = engine.state.title ?? '';
    _artist = engine.state.artist ?? '';
    _load();
  }

  Future<void> _load() async {
    final l = await LyricsService.instance.fetch(_artist, _title);
    if (!mounted) return;
    setState(() {
      _lyrics = l;
      _loading = false;
    });
  }

  void _maybeScroll(int index, ColorScheme cs) {
    if (index == _lastIndex || !_scroll.hasClients) return;
    _lastIndex = index;
    if (index < 0) return;
    // ~56px per line; keep the active line slightly above center.
    final target = (index * 56.0 - 140.0).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lyrics_outlined, color: cs.primary, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(loc.lyrics,
                            style: TextStyle(
                                color: cs.onSurface,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        Text('$_title — $_artist',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 12)),
                      ],
                    ),
                  ),
                  if (_lyrics?.isSynced == true)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(loc.lyricsSynced,
                          style: TextStyle(
                              color: cs.primary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildBody(loc, cs)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations loc, ColorScheme cs) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(loc.lyricsLoading,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ],
        ),
      );
    }
    final lyrics = _lyrics;
    if (lyrics == null || lyrics.isEmpty) {
      return Center(
        child: Text(loc.lyricsNotFound,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
      );
    }
    if (lyrics.isSynced) return _buildSynced(lyrics, cs);
    return SingleChildScrollView(
      child: SelectableText(
        lyrics.plain!,
        style: TextStyle(color: cs.onSurface, fontSize: 15, height: 1.7),
      ),
    );
  }

  Widget _buildSynced(Lyrics lyrics, ColorScheme cs) {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final index =
            LyricsService.lineIndexAt(lyrics.synced, engine.position);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeScroll(index, cs);
        });
        return ListView.builder(
          controller: _scroll,
          itemCount: lyrics.synced.length,
          itemBuilder: (context, i) {
            final active = i == index;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: active
                  ? BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    )
                  : null,
              child: Text(
                lyrics.synced[i].text,
                style: TextStyle(
                  color: active ? cs.primary : cs.onSurfaceVariant,
                  fontSize: active ? 17 : 15,
                  fontWeight:
                      active ? FontWeight.w700 : FontWeight.w400,
                  height: 1.5,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Opens the lyrics sheet from anywhere in the player.
void showLyricsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const LyricsSheet(),
  );
}
