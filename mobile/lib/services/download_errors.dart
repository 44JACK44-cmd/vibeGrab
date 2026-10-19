import 'dart:convert';

import '../data/models/download_task.dart';

/// One backend failure, as described by the server itself.
///
/// Every download endpoint answers with the same shape:
///
/// ```json
/// {"success": false, "error_code": "source_unavailable",
///  "stage": "extract", "detail": "...", "request_id": "a1b2c3"}
/// ```
///
/// The client used to reduce all of them to `httpError` → "Error del
/// servidor", which hid whether the source was unreachable, the conversion
/// failed or the request itself was malformed. This keeps the real code,
/// stage and request id so the UI can say what happened and the log can be
/// correlated with the server.
class BackendErrorInfo {
  final int status;
  final String? code;
  final String? stage;
  final String? detail;
  final String? requestId;

  const BackendErrorInfo({
    required this.status,
    this.code,
    this.stage,
    this.detail,
    this.requestId,
  });

  bool get isEmpty => code == null && detail == null && requestId == null;
}

/// Parses the JSON error body. Never throws: a non-JSON body (proxy page,
/// HTML error) still yields the HTTP status.
BackendErrorInfo parseBackendError(int status, String body) {
  Map<String, dynamic>? json;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) json = decoded;
  } catch (_) {
    // Some proxies answer with HTML; the status is still useful.
  }
  if (json == null) {
    // Older backends only sent {"detail": "..."} — keep that too.
    final m = RegExp(r'"detail"\s*:\s*"([^"]+)"').firstMatch(body);
    return BackendErrorInfo(
      status: status,
      detail: m?.group(1)?.replaceAll(r'\"', '"'),
    );
  }
  String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  return BackendErrorInfo(
    status: status,
    code: str(json['error_code']),
    stage: str(json['stage']),
    detail: str(json['detail']),
    requestId: str(json['request_id']),
  );
}

/// Backend `error_code` → the app's own error type.
DownloadErrorType errorTypeOf(BackendErrorInfo error) {
  switch (error.code) {
    case 'source_unavailable':
    case 'no_formats':
      return DownloadErrorType.sourceUnavailable;
    case 'conversion_failed':
      return DownloadErrorType.conversionFailed;
    case 'merge_failed':
      return DownloadErrorType.mergeFailed;
    case 'file_too_large':
      return DownloadErrorType.fileTooLarge;
    case 'invalid_request':
    case 'invalid_format':
    case 'unsupported_url':
      return DownloadErrorType.invalidRequest;
  }
  if (error.status == 403) return DownloadErrorType.http403;
  if (error.status == 408 || error.status == 504) {
    return DownloadErrorType.serverTimeout;
  }
  if (error.status >= 500) return DownloadErrorType.httpError;
  return DownloadErrorType.unexpectedResponse;
}

/// Technical line for the log (and the `task.error` field). No signed URLs,
/// no tokens: only the code/stage/request id the server reported.
String describeBackendError(
  BackendErrorInfo error, {
  String operation = 'download',
}) {
  final parts = <String>[
    'op=$operation',
    'status=${error.status}',
    if (error.code != null) 'code=${error.code}',
    if (error.stage != null) 'stage=${error.stage}',
    if (error.requestId != null) 'request_id=${error.requestId}',
    if (error.detail != null) 'detail=${_sanitize(error.detail!)}',
  ];
  return parts.join(' ');
}

/// Trims a server detail to something loggable: no newlines, no URLs.
String _sanitize(String detail) {
  var text = detail.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Signed media URLs may appear inside a provider error; keep the host only.
  text = text.replaceAllMapped(
    RegExp(r'https?://([^/\s]+)[^\s]*'),
    (m) => 'https://${m.group(1)}/…',
  );
  if (text.length > 240) text = '${text.substring(0, 240)}…';
  return text;
}

/// True when the first bytes of a file match the container its extension
/// promises.
///
/// A produced download is only marked complete after this: a non-empty file
/// can still be a proxy error page or the wrong container (the old
/// "video saved as .mp3" failure). The check is on signatures, not names.
bool matchesContainerHeader(List<int> head, String ext) {
  if (head.length < 4) return false;
  switch (ext.toLowerCase()) {
    case 'mp3':
      final id3 = head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33;
      final frameSync = head[0] == 0xFF && (head[1] & 0xE0) == 0xE0;
      return id3 || frameSync;
    case 'mp4':
    case 'm4a':
    case 'm4v':
    case 'mov':
      if (head.length < 8) return false;
      // "ftyp" on a complete file, "styp" on a fragmented MP4 segment.
      final box = String.fromCharCodes(head.sublist(4, 8));
      return box == 'ftyp' || box == 'styp';
    case 'mkv':
    case 'webm':
      return head[0] == 0x1A &&
          head[1] == 0x45 &&
          head[2] == 0xDF &&
          head[3] == 0xA3; // EBML
    default:
      return true;
  }
}
