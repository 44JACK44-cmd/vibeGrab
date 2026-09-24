import 'media_info.dart';
import 'format_option.dart';

class AnalyzeResponse {
  final bool success;
  final MediaInfo media;
  final List<FormatOption> formats;

  AnalyzeResponse({required this.success, required this.media, required this.formats});

  factory AnalyzeResponse.fromJson(Map<String, dynamic> json) {
    return AnalyzeResponse(
      success: json['success'] ?? false,
      media: MediaInfo.fromJson(json['media']),
      formats: (json['formats'] as List)
          .map((f) => FormatOption.fromJson(f))
          .toList(),
    );
  }
}
