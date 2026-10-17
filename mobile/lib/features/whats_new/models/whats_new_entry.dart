import 'package:flutter/foundation.dart';

/// Kind of change, used to group the presentation into sections.
///
/// The order of the values is also the display order of the sections.
enum WhatsNewCategory { features, improvements, fixes, stability }

/// A short piece of text available in every supported locale.
@immutable
class LocalizedText {
  final String es;
  final String en;

  const LocalizedText({required this.es, required this.en});

  /// Falls back to Spanish for any language that is not English.
  String resolve(String languageCode) => languageCode == 'en' ? en : es;
}

/// A single user-facing change belonging to one app version.
///
/// These entries are the source of the "What's New" experience. They describe
/// the *benefit* for the user, never the commit or implementation detail.
@immutable
class WhatsNewEntry {
  final String id;

  /// Version name, e.g. `1.1.34`.
  final String version;

  /// Build number (`versionCode`), e.g. `39`.
  final int build;

  final WhatsNewCategory category;
  final String emoji;
  final LocalizedText title;
  final LocalizedText description;

  /// Sort position inside its category (lower shows first).
  final int order;

  /// Highlighted card in the presentation.
  final bool featured;

  const WhatsNewEntry({
    required this.id,
    required this.version,
    required this.build,
    required this.category,
    required this.emoji,
    required this.title,
    required this.description,
    this.order = 0,
    this.featured = false,
  });
}

/// All entries that belong to one version, ready to be shown as a group.
@immutable
class WhatsNewVersionGroup {
  final String version;
  final int build;
  final List<WhatsNewEntry> entries;

  const WhatsNewVersionGroup({
    required this.version,
    required this.build,
    required this.entries,
  });
}

/// Entries of a single category, already ordered for display.
@immutable
class WhatsNewSection {
  final WhatsNewCategory category;
  final List<WhatsNewEntry> entries;

  const WhatsNewSection({required this.category, required this.entries});
}
