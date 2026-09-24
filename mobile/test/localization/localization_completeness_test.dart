import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> enArb;
  late Map<String, dynamic> esArb;

  setUpAll(() {
    final enJson = File('lib/core/localization/app_en.arb').readAsStringSync();
    final esJson = File('lib/core/localization/app_es.arb').readAsStringSync();
    enArb = json.decode(enJson) as Map<String, dynamic>;
    esArb = json.decode(esJson) as Map<String, dynamic>;
  });

  group('ARB completeness', () {
    test('EN and ES have same non-metadata keys', () {
      final enKeys = enArb.keys.where((k) => !k.startsWith('@')).toSet();
      final esKeys = esArb.keys.where((k) => !k.startsWith('@')).toSet();

      final missingInEs = enKeys.difference(esKeys);
      final missingInEn = esKeys.difference(enKeys);

      expect(missingInEs, isEmpty, reason: 'Keys in EN but not ES: $missingInEs');
      expect(missingInEn, isEmpty, reason: 'Keys in ES but not EN: $missingInEn');
    });

    test('all parametric keys have matching @-metadata', () {
      final regex = RegExp(r'\{(\w+)\}');
      for (final arb in [enArb, esArb]) {
        for (final entry in arb.entries) {
          if (entry.key.startsWith('@')) continue;
          final matches = regex.allMatches(entry.value.toString());
          if (matches.isNotEmpty) {
            final metadataKey = '@${entry.key}';
            expect(
              arb.containsKey(metadataKey),
              isTrue,
              reason: 'Key "${entry.key}" has placeholders but no "$metadataKey"',
            );
          }
        }
      }
    });

    test('no empty string values', () {
      for (final arb in [enArb, esArb]) {
        for (final entry in arb.entries) {
          if (entry.key.startsWith('@')) continue;
          expect(
            entry.value.toString().isNotEmpty,
            isTrue,
            reason: 'Key "${entry.key}" has empty value',
          );
        }
      }
    });

    test('version string is updated', () {
      expect(enArb['appVersion'], isNot('v0.1.0'));
      expect(esArb['appVersion'], isNot('v0.1.0'));
    });
  });
}
