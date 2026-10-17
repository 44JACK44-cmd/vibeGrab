import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/update_service.dart';
import 'data/whats_new_catalog.dart';
import 'models/whats_new_entry.dart';
import 'widgets/whats_new_dialog.dart';

/// What the app should do when it starts with a given version.
enum WhatsNewAction {
  /// Nothing to do (already seen, or no registered changes).
  none,

  /// Only record the version as seen (fresh install with no entries).
  markOnly,

  /// Record the version and present the changes.
  show,
}

/// Result of [WhatsNewService.resolve].
@immutable
class WhatsNewDecision {
  final WhatsNewAction action;
  final List<WhatsNewVersionGroup> groups;

  const WhatsNewDecision(this.action, [this.groups = const []]);
}

/// Shows the "What's New" presentation after the app is updated.
///
/// The mechanism is deliberately simple and offline: the notes ship inside the
/// app (see [WhatsNewCatalog]) and the only stored state is the last version
/// the user has already been shown. That way the presentation appears once per
/// update, without repeating and without presenting old changes as new.
class WhatsNewService {
  WhatsNewService._();

  static const String _prefKey = 'whats_new_last_seen_version';

  /// Pure decision logic, kept free of platform channels so it is testable.
  ///
  /// * [seenVersion] is the last version already presented (null on first run).
  /// * Anything strictly newer than `seen` and not newer than `current` is
  ///   shown, so users who skipped several releases see everything at once.
  static WhatsNewDecision resolve({
    required String? seenVersion,
    required int seenBuild,
    required String currentVersion,
    required int currentBuild,
  }) {
    if (currentVersion.isEmpty || currentVersion == '0.0.0') {
      return const WhatsNewDecision(WhatsNewAction.none);
    }

    if (seenVersion == null) {
      // First run with this feature: never dump the whole history. Only the
      // version actually installed is presented (if it has entries).
      final current = WhatsNewCatalog.forVersion(currentVersion, currentBuild);
      if (current.isEmpty) {
        return const WhatsNewDecision(WhatsNewAction.markOnly);
      }
      return WhatsNewDecision(
        WhatsNewAction.show,
        WhatsNewCatalog.groupByVersion(current),
      );
    }

    final changes = WhatsNewCatalog.changesSince(
      lastVersion: seenVersion,
      lastBuild: seenBuild,
      currentVersion: currentVersion,
      currentBuild: currentBuild,
    );
    if (changes.isEmpty) {
      return const WhatsNewDecision(WhatsNewAction.none);
    }
    return WhatsNewDecision(
      WhatsNewAction.show,
      WhatsNewCatalog.groupByVersion(changes),
    );
  }

  /// Called once from the app shell shortly after start-up.
  static Future<void> maybeShow(BuildContext context) async {
    try {
      final current = await UpdateService.currentVersion();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      final seen = raw == null ? null : _decode(raw);

      final decision = resolve(
        seenVersion: seen?.version,
        seenBuild: seen?.build ?? 0,
        currentVersion: current.version,
        currentBuild: current.build,
      );

      switch (decision.action) {
        case WhatsNewAction.none:
          return;
        case WhatsNewAction.markOnly:
          await _markSeen(prefs, current.version, current.build);
          return;
        case WhatsNewAction.show:
          // Persist before presenting so it can never show twice, even if the
          // app is closed while the user is still reading.
          await _markSeen(prefs, current.version, current.build);
          if (!context.mounted) return;
          await WhatsNewDialog.show(context, groups: decision.groups);
      }
    } catch (e) {
      debugPrint('[WhatsNew] skipped: $e');
    }
  }

  /// Opens the notes for the newest registered version (used from Settings).
  static Future<void> showLatest(BuildContext context) async {
    final groups = WhatsNewCatalog.latestGroups(maxVersions: 1);
    if (groups.isEmpty || !context.mounted) return;
    await WhatsNewDialog.show(context, groups: groups, isUpdate: false);
  }

  static Future<void> _markSeen(
    SharedPreferences prefs,
    String version,
    int build,
  ) =>
      prefs.setString(_prefKey, _encode(version, build));

  static String _encode(String version, int build) => '$version+$build';

  static ({String version, int build})? _decode(String raw) {
    final plus = raw.lastIndexOf('+');
    if (plus <= 0 || plus == raw.length - 1) return null;
    final version = raw.substring(0, plus);
    final build = int.tryParse(raw.substring(plus + 1));
    if (build == null) return null;
    return (version: version, build: build);
  }
}
