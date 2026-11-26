import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

/// Real-network check of the YouTube extraction path used by the share
/// sheet. It is opt-in because CI runners share an IP that YouTube blocks:
/// run with VIBEGRAB_REAL_NETWORK_TEST=1 on a normal connection.
void main() {
  final enabled = Platform.environment['VIBEGRAB_REAL_NETWORK_TEST'] == '1';

  test('real YouTube extraction yields video and audio formats', () async {
    if (!enabled) {
      // The mocked analysis tests cover the same contract offline.
      return;
    }
    final service = LocalExtractionService();
    try {
      final result = await service
          .extractMedia('https://www.youtube.com/watch?v=dQw4w9WgXcQ')
          .timeout(const Duration(seconds: 45));
      expect(result.media.title, isNotEmpty);
      expect(result.formats.any((f) => f.hasVideo), isTrue);
      expect(result.formats.any((f) => f.type == 'audio'), isTrue);
    } finally {
      service.dispose();
    }
  });
}
