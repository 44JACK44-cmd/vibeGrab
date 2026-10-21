import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/features/whats_new/data/whats_new_catalog.dart';
import 'package:vibegrab/features/whats_new/models/whats_new_entry.dart';
import 'package:vibegrab/features/whats_new/whats_new_service.dart';

void main() {
  group('WhatsNewCatalog integrity', () {
    test('has entries', () {
      expect(WhatsNewCatalog.entries, isNotEmpty);
    });

    test('ids are unique and versions look like x.y.z or x.y.z.p', () {
      final ids = WhatsNewCatalog.entries.map((e) => e.id).toSet();
      expect(ids.length, WhatsNewCatalog.entries.length);
      final re = RegExp(r'^\d+\.\d+\.\d+(?:\.\d+)?$');
      for (final e in WhatsNewCatalog.entries) {
        expect(re.hasMatch(e.version), isTrue, reason: e.id);
        expect(e.build, greaterThan(0), reason: e.id);
      }
    });

    test('every entry is written in both languages', () {
      for (final e in WhatsNewCatalog.entries) {
        expect(e.title.es.trim(), isNotEmpty, reason: e.id);
        expect(e.title.en.trim(), isNotEmpty, reason: e.id);
        expect(e.description.es.trim(), isNotEmpty, reason: e.id);
        expect(e.description.en.trim(), isNotEmpty, reason: e.id);
        expect(e.emoji.trim(), isNotEmpty, reason: e.id);
      }
    });

    test('does not repeat the same title inside a version/category', () {
      final seen = <String>{};
      for (final e in WhatsNewCatalog.entries) {
        final key = '${e.version}+${e.build}|${e.category}|${e.title.es}';
        expect(seen.add(key), isTrue, reason: 'duplicado: ${e.id}');
      }
    });
  });

  group('compare', () {
    test('orders by version and then by build', () {
      expect(WhatsNewCatalog.compare('1.1.34', 39, '1.1.33', 38), greaterThan(0));
      expect(WhatsNewCatalog.compare('1.1.33', 38, '1.1.34', 39), lessThan(0));
      expect(WhatsNewCatalog.compare('1.1.34', 39, '1.1.34', 39), 0);
      expect(WhatsNewCatalog.compare('1.1.34', 38, '1.1.34', 39), lessThan(0));
      expect(WhatsNewCatalog.compare('1.2.0', 1, '1.1.99', 99), greaterThan(0));
    });
  });

  group('changesSince', () {
    test('returns every version skipped since the last one seen', () {
      final changes = WhatsNewCatalog.changesSince(
        lastVersion: '1.1.30',
        lastBuild: 35,
        currentVersion: '1.1.32',
        currentBuild: 37,
      );
      expect(changes.map((e) => e.version).toSet(), {'1.1.31', '1.1.32'});
    });

    test('is empty when already up to date', () {
      final changes = WhatsNewCatalog.changesSince(
        lastVersion: '1.1.34',
        lastBuild: 39,
        currentVersion: '1.1.34',
        currentBuild: 39,
      );
      expect(changes, isEmpty);
    });

    test('never returns versions newer than the installed one', () {
      final changes = WhatsNewCatalog.changesSince(
        lastVersion: '1.1.20',
        lastBuild: 20,
        currentVersion: '1.1.26',
        currentBuild: 31,
      );
      expect(changes.every((e) => e.version == '1.1.26'), isTrue);
      expect(changes, isNotEmpty);
    });
  });

  group('grouping and sections', () {
    test('groupByVersion sorts newest first', () {
      final groups = WhatsNewCatalog.groupByVersion(WhatsNewCatalog.entries);
      expect(groups.first.version, '1.1.42');
      for (var i = 1; i < groups.length; i++) {
        expect(
          WhatsNewCatalog.compare(
            groups[i - 1].version,
            groups[i - 1].build,
            groups[i].version,
            groups[i].build,
          ),
          greaterThan(0),
        );
      }
    });

    test('sectionsOf keeps category order and drops empty sections', () {
      final sections = WhatsNewCatalog.sectionsOf(WhatsNewCatalog.entries);
      expect(sections, isNotEmpty);
      expect(sections.every((s) => s.entries.isNotEmpty), isTrue);
      for (var i = 0; i < sections.length; i++) {
        expect(sections[i].category, WhatsNewCatalog.categoryOrder[i]);
      }
    });

    test('highlights puts featured first and respects the cap', () {
      final list = WhatsNewCatalog.forVersion('1.1.33', 38);
      final highlights = WhatsNewCatalog.highlights(list, max: 2);
      expect(highlights.length, lessThanOrEqualTo(2));
      expect(highlights.first.featured, isTrue);
    });
  });

  group('WhatsNewService.resolve', () {
    test('fresh install shows only the installed version', () {
      final decision = WhatsNewService.resolve(
        seenVersion: null,
        seenBuild: 0,
        currentVersion: '1.1.34',
        currentBuild: 39,
      );
      expect(decision.action, WhatsNewAction.show);
      expect(decision.groups.length, 1);
      expect(decision.groups.first.version, '1.1.34');
    });

    test('fresh install of an unknown version only marks it as seen', () {
      final decision = WhatsNewService.resolve(
        seenVersion: null,
        seenBuild: 0,
        currentVersion: '9.9.9',
        currentBuild: 999,
      );
      expect(decision.action, WhatsNewAction.markOnly);
    });

    test('update shows the backlog since the last seen version', () {
      final decision = WhatsNewService.resolve(
        seenVersion: '1.1.30',
        seenBuild: 35,
        currentVersion: '1.1.33',
        currentBuild: 38,
      );
      expect(decision.action, WhatsNewAction.show);
      expect(
        decision.groups.map((g) => g.version),
        ['1.1.33', '1.1.32', '1.1.31'],
      );
    });

    test('nothing to show on the same version', () {
      final decision = WhatsNewService.resolve(
        seenVersion: '1.1.34',
        seenBuild: 39,
        currentVersion: '1.1.34',
        currentBuild: 39,
      );
      expect(decision.action, WhatsNewAction.none);
      expect(decision.groups, isEmpty);
    });

    test('ignores an unavailable version channel', () {
      final decision = WhatsNewService.resolve(
        seenVersion: '1.1.30',
        seenBuild: 35,
        currentVersion: '0.0.0',
        currentBuild: 0,
      );
      expect(decision.action, WhatsNewAction.none);
    });

    test('nothing when the recorded version is newer (downgrade)', () {
      final decision = WhatsNewService.resolve(
        seenVersion: '1.1.40',
        seenBuild: 50,
        currentVersion: '1.1.34',
        currentBuild: 39,
      );
      expect(decision.action, WhatsNewAction.none);
    });
  });

  group('LocalizedText', () {
    test('resolves english and falls back to spanish', () {
      const text = LocalizedText(es: 'hola', en: 'hello');
      expect(text.resolve('en'), 'hello');
      expect(text.resolve('es'), 'hola');
      expect(text.resolve('fr'), 'hola');
    });
  });
}
