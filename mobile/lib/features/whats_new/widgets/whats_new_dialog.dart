import 'package:flutter/material.dart';

import '../../../core/localization/app_localizations.dart';
import '../data/whats_new_catalog.dart';
import '../models/whats_new_entry.dart';

/// Presents the changes of one or more versions as a modern "What's New"
/// experience: a highlighted header, category sections and entry cards.
class WhatsNewDialog {
  WhatsNewDialog._();

  static Future<void> show(
    BuildContext context, {
    required List<WhatsNewVersionGroup> groups,
    bool isUpdate = true,
  }) {
    if (groups.isEmpty) return Future.value();
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _WhatsNewDialog(groups: groups, isUpdate: isUpdate),
    );
  }
}

class _WhatsNewDialog extends StatelessWidget {
  final List<WhatsNewVersionGroup> groups;
  final bool isUpdate;

  const _WhatsNewDialog({required this.groups, required this.isUpdate});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final allEntries = [
      for (final group in groups) ...group.entries,
    ];
    final sections = WhatsNewCatalog.sectionsOf(allEntries);
    final showVersionTag = groups.length > 1;

    final title = isUpdate ? loc.whatsNewTitle : loc.whatsNewTitleManual;
    final subtitle =
        groups.length > 1 ? loc.whatsNewSinceLast : loc.whatsNewSubtitle;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              title: title,
              subtitle: subtitle,
              versionLabels: [
                for (final group in groups)
                  loc.whatsNewVersion(group.version),
              ],
              onClose: () => Navigator.of(context).maybePop(),
              closeLabel: loc.whatsNewClose,
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, section) in sections.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 22),
                        child: _Section(
                          section: section,
                          languageCode: lang,
                          animationSeed: index,
                          showVersionTag: showVersionTag,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
                ),
              ),
              child: FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  loc.whatsNewGotIt,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<String> versionLabels;
  final VoidCallback onClose;
  final String closeLabel;

  const _Header({
    required this.title,
    required this.subtitle,
    required this.versionLabels,
    required this.onClose,
    required this.closeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primary.withValues(alpha: 0.20),
            cs.primary.withValues(alpha: 0.03),
          ],
        ),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [cs.primary, cs.secondary],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: cs.primary.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Icon(Icons.auto_awesome, color: cs.onPrimary, size: 30),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: text.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                if (versionLabels.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final label in versionLabels)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: cs.primary.withValues(alpha: 0.30),
                            ),
                          ),
                          child: Text(
                            label,
                            style: text.labelMedium?.copyWith(
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close),
              color: cs.onSurfaceVariant,
              tooltip: closeLabel,
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final WhatsNewSection section;
  final String languageCode;
  final int animationSeed;
  final bool showVersionTag;

  const _Section({
    required this.section,
    required this.languageCode,
    required this.animationSeed,
    required this.showVersionTag,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Row(
            children: [
              ExcludeSemantics(
                child: Text(
                  _categoryEmoji(section.category),
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _categoryLabel(loc, section.category),
                style: text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final (index, entry) in section.entries.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _AnimatedIn(
              index: animationSeed * 3 + index,
              child: _EntryCard(
                entry: entry,
                languageCode: languageCode,
                showVersionTag: showVersionTag,
              ),
            ),
          ),
      ],
    );
  }
}

class _EntryCard extends StatelessWidget {
  final WhatsNewEntry entry;
  final String languageCode;
  final bool showVersionTag;

  const _EntryCard({
    required this.entry,
    required this.languageCode,
    required this.showVersionTag,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = entry.title.resolve(languageCode);
    final description = entry.description.resolve(languageCode);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: entry.featured
            ? cs.primary.withValues(alpha: 0.10)
            : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: entry.featured
              ? cs.primary.withValues(alpha: 0.45)
              : cs.outlineVariant.withValues(alpha: 0.5),
          width: entry.featured ? 1.3 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: ExcludeSemantics(
              child: Text(entry.emoji, style: const TextStyle(fontSize: 20)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: text.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                if (showVersionTag) ...[
                  const SizedBox(height: 6),
                  Text(
                    'v${entry.version}',
                    style: text.labelSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Very light entrance animation: fade + a small upward slide.
class _AnimatedIn extends StatelessWidget {
  final int index;
  final Widget child;

  const _AnimatedIn({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      curve: Curves.easeOut,
      duration: Duration(milliseconds: 220 + (index.clamp(0, 10) * 25)),
      builder: (context, value, animChild) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 10),
          child: animChild,
        ),
      ),
      child: child,
    );
  }
}

String _categoryLabel(AppLocalizations loc, WhatsNewCategory category) {
  switch (category) {
    case WhatsNewCategory.features:
      return loc.whatsNewCatFeatures;
    case WhatsNewCategory.improvements:
      return loc.whatsNewCatImprovements;
    case WhatsNewCategory.fixes:
      return loc.whatsNewCatFixes;
    case WhatsNewCategory.stability:
      return loc.whatsNewCatStability;
  }
}

String _categoryEmoji(WhatsNewCategory category) {
  switch (category) {
    case WhatsNewCategory.features:
      return '✨';
    case WhatsNewCategory.improvements:
      return '🚀';
    case WhatsNewCategory.fixes:
      return '🛠️';
    case WhatsNewCategory.stability:
      return '🔒';
  }
}
