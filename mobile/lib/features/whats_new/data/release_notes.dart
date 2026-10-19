/// Parses the notes that travel with a GitHub release into something the app
/// can present properly.
///
/// The installed app only knows the versions compiled into
/// `WhatsNewCatalog`, so the FIRST update someone receives after installing
/// arrives without catalogue entries: the only thing the app can show is the
/// text of the release. Two shapes reach this parser:
///
///  * the notes written for the release (`docs/releases/X.Y.Z.md`), made of
///    `## Section` headers and `- **Title** — body` bullets, optionally in
///    both languages behind `<!-- es -->` / `<!-- en -->` markers;
///  * the text GitHub generates out of the commits, which is full of noise
///    ("What's Changed", "by @user in <url>", "New Contributors", "Full
///    Changelog"). The noise is dropped and whatever survives is presented
///    as a single section.
///
/// Returns null when there is nothing worth showing, so the caller can fall
/// back to the plain text.
class ReleaseNotes {
  const ReleaseNotes._();

  /// Sections of the notes written for [languageCode], or null when the text
  /// carries nothing presentable.
  static List<ReleaseNoteSection>? parse(String raw, String languageCode) {
    final text = _pickLanguage(raw, languageCode);
    if (text == null) return null;

    final sections = <ReleaseNoteSection>[];
    var title = '';
    var items = <ReleaseNoteItem>[];

    void flush() {
      if (items.isEmpty) return;
      sections.add(ReleaseNoteSection(
        title: title.trim(),
        items: List<ReleaseNoteItem>.unmodifiable(items),
      ));
      items = <ReleaseNoteItem>[];
    }

    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('## ')) {
        flush();
        // A generated header ("What's Changed") is noise too: keep the
        // items but not the title.
        title = _isNoise(trimmed) ? '' : trimmed.substring(3);
        continue;
      }
      if (_isNoise(trimmed)) continue;
      final item = _itemOf(trimmed);
      if (item != null) items.add(item);
    }
    flush();

    if (sections.isEmpty) return null;
    return List<ReleaseNoteSection>.unmodifiable(sections);
  }

  /// Picks the block written for [languageCode] when the notes carry the
  /// `<!-- xx -->` markers, falling back to Spanish and then to the whole
  /// text (notes without markers are already single-language).
  static String? _pickLanguage(String raw, String languageCode) {
    final text = raw.replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return null;

    final marker = RegExp(r'^<!--\s*([a-z]{2})\s*-->$', multiLine: true);
    final matches = marker.allMatches(text).toList();
    if (matches.isEmpty) return text;

    String? block(String lang) {
      for (var i = 0; i < matches.length; i++) {
        if (matches[i][1] != lang) continue;
        final start = matches[i].end;
        final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
        return text.substring(start, end);
      }
      return null;
    }

    return block(languageCode) ?? block('es') ?? text;
  }

  /// GitHub's generated notes: section headers nobody wants to read and
  /// bullets that are really commit credits.
  static bool _isNoise(String line) {
    final lower = line.toLowerCase();
    if (lower.contains("what's changed") || lower.contains('new contributors')) {
      return true;
    }
    if (line.startsWith('**Full Changelog**')) return true;
    // "* Title by @user in <url>" / "* @user made their first contribution".
    // GitHub handles contain hyphens, so \w alone is not enough.
    if (RegExp(r'^[*-]\s+@[\w-]+').hasMatch(line)) return true;
    if (RegExp(r'by\s+@[\w-]+\s+in\s+https?://').hasMatch(line)) return true;
    return false;
  }

  static ReleaseNoteItem? _itemOf(String rawLine) {
    var line = rawLine.trim();
    if (line.startsWith('- ') || line.startsWith('* ')) {
      line = line.substring(2).trim();
    } else if (line == '-' || line == '*') {
      return null;
    }
    if (line.isEmpty) return null;

    // The icon comes off first: otherwise the bold matcher stops at the
    // "**" that opens the title and swallows the emoji into it.
    var emoji = '';
    final split = _splitEmoji(line);
    if (split != null) {
      emoji = split.$1;
      line = split.$2;
    }

    var title = '';
    var body = '';
    final bold = RegExp(r'^\*\*(.+?)\*\*(.*)$').firstMatch(line);
    if (bold != null) {
      title = bold[1]!.trim();
      body = _withoutSeparator(bold[2] ?? '');
    } else {
      // A line with no title is a note of its own: keep it whole.
      body = _withoutSeparator(line);
    }

    if (title.isEmpty && body.isEmpty) return null;
    return ReleaseNoteItem(emoji: emoji, title: title, body: body);
  }

  static String _withoutSeparator(String value) {
    var text = value.trim();
    for (final sep in ['—', '–', '-', ':']) {
      if (text.startsWith(sep)) {
        text = text.substring(1).trim();
        break;
      }
    }
    return text.replaceAll('**', '').trim();
  }

  /// Takes the leading emoji (with its variation selector and joins) off a
  /// title, so the icon can be shown in its own box like the catalogue does.
  static (String, String)? _splitEmoji(String title) {
    final runes = title.runes.toList();
    var i = 0;
    while (i < runes.length && _isEmojiRune(runes[i])) {
      i++;
    }
    if (i == 0) return null;
    final emoji = String.fromCharCodes(runes.sublist(0, i)).trim();
    if (emoji.isEmpty) return null;
    final rest = String.fromCharCodes(runes.sublist(i)).trim();
    return (emoji, rest);
  }

  static bool _isEmojiRune(int rune) =>
      (rune >= 0x1F000) // emoji blocks (📥 🎬 🔒 …)
      || (rune >= 0x2600 && rune <= 0x27BF) // ✨ ⚡ 🛠️ …
      || (rune >= 0x25A0 && rune <= 0x25FF) // ▶ ■ …
      || (rune >= 0x2B00 && rune <= 0x2BFF) // ⭐ …
      || rune == 0xFE0F // variation selector
      || rune == 0x200D; // zero-width joiner
}

/// One thing that changed, as written in the release notes.
class ReleaseNoteItem {
  final String emoji;
  final String title;
  final String body;

  const ReleaseNoteItem({
    required this.emoji,
    required this.title,
    required this.body,
  });
}

/// A group of changes under a header, as written in the release notes.
class ReleaseNoteSection {
  final String title;
  final List<ReleaseNoteItem> items;

  const ReleaseNoteSection({required this.title, required this.items});
}
