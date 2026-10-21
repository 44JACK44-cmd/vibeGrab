import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/features/ads/models/ad_placement.dart';
import 'package:vibegrab/features/ads/services/ad_metrics.dart';

void main() {
  test('records only explicit, provider-shaped events', () {
    final metrics = AdMetrics(
      logEvents: false,
      clock: () => DateTime(2026, 1, 1, 12),
    );

    metrics.record(AdMetricEvent.request, AdPlacement.homeBanner);
    metrics.record(AdMetricEvent.loaded, AdPlacement.homeBanner);
    metrics.record(AdMetricEvent.impression, AdPlacement.homeBanner);
    metrics.record(
      AdMetricEvent.failed,
      AdPlacement.libraryBanner,
      errorCode: 3,
    );

    expect(metrics.count(AdMetricEvent.request), 1);
    expect(metrics.count(AdMetricEvent.loaded), 1);
    expect(metrics.count(AdMetricEvent.impression), 1);
    expect(metrics.count(AdMetricEvent.failed), 1);
    expect(
      metrics.count(AdMetricEvent.failed, placement: AdPlacement.libraryBanner),
      1,
    );
    expect(metrics.entries.last.errorCode, 3);
  });

  test('caps the in-memory event buffer', () {
    final metrics = AdMetrics(logEvents: false);
    for (var i = 0; i < 250; i++) {
      metrics.record(AdMetricEvent.request, AdPlacement.homeBanner);
    }

    expect(metrics.entries.length, 200);
  });
}
