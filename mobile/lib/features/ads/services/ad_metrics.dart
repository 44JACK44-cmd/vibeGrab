import 'package:flutter/foundation.dart';

import '../models/ad_placement.dart';

/// Real, locally recorded ad events.
///
/// This class deliberately does not estimate revenue, impressions or clicks.
/// Events only come from the provider's callbacks, and the buffer is bounded so
/// a long session cannot grow memory without limit. Nothing here is uploaded
/// and no user identifier, page URL or search query is stored.
enum AdMetricEvent {
  request,
  loaded,
  impression,
  clicked,
  failed,
  interstitialShown,
  dismissed,
}

@immutable
class AdMetricEntry {
  const AdMetricEntry({
    required this.event,
    required this.placement,
    required this.at,
    this.errorCode,
  });

  final AdMetricEvent event;
  final AdPlacement placement;
  final DateTime at;
  final int? errorCode;

  @override
  String toString() {
    final code = errorCode == null ? '' : ' code=$errorCode';
    return '${event.name} ${placement.id}$code';
  }
}

class AdMetrics {
  AdMetrics({this.logEvents = kDebugMode, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const int _maxEntries = 200;

  final bool logEvents;
  final DateTime Function() _clock;
  final List<AdMetricEntry> _entries = <AdMetricEntry>[];

  List<AdMetricEntry> get entries => List<AdMetricEntry>.unmodifiable(_entries);

  void record(AdMetricEvent event, AdPlacement placement, {int? errorCode}) {
    final entry = AdMetricEntry(
      event: event,
      placement: placement,
      at: _clock(),
      errorCode: errorCode,
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    if (logEvents) {
      debugPrint('[Ads] $entry');
    }
  }

  int count(AdMetricEvent event, {AdPlacement? placement}) {
    return _entries.where((entry) {
      return entry.event == event &&
          (placement == null || entry.placement == placement);
    }).length;
  }

  void clear() => _entries.clear();
}
