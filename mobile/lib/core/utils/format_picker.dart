import '../../data/models/format_option.dart';

class FormatPicker {
  static int _heightOf(FormatOption f) {
    final q = f.quality ?? '';
    if (q.endsWith('p')) return int.tryParse(q.substring(0, q.length - 1)) ?? 0;
    return 0;
  }

  static FormatOption? pick({
    required List<FormatOption> video,
    required List<FormatOption> audio,
    required String quality,
  }) {
    if (video.isEmpty && audio.isEmpty) return null;

    if (quality == 'audio') {
      if (audio.isNotEmpty) return audio.first;
      return video.first;
    }

    if (video.isEmpty) return audio.first;

    if (quality == 'best') {
      var best = video.first;
      for (final f in video) {
        if (_heightOf(f) > _heightOf(best)) best = f;
      }
      return best;
    }

    final target = int.tryParse(quality.replaceAll('p', ''));
    if (target == null) return video.first;

    FormatOption? fit;
    var fitHeight = -1;
    for (final f in video) {
      final h = _heightOf(f);
      if (h <= target && h > fitHeight) {
        fit = f;
        fitHeight = h;
      }
    }
    if (fit != null) return fit;

    var best = video.first;
    for (final f in video) {
      if (_heightOf(f) > _heightOf(best)) best = f;
    }
    return best;
  }
}
