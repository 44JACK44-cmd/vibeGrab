/// Typed analysis failures shared by the device extractor and the backend
/// client.
///
/// Before this existed, every failure (an HTML error page, a 502, a timeout,
/// a private video) ended up as the same generic string, so the user could not
/// tell whether the link, the server, the format or the conversion was wrong.
/// Each cause now maps to a stable key that the UI localizes.
enum AnalysisFailureType {
  /// The text is not a URL at all (or not a complete one).
  invalidUrl,

  /// A real URL, but from a host the app cannot resolve.
  unsupportedPlatform,

  /// The device could not reach the network / the socket failed.
  network,

  /// A request did not answer within its budget.
  timeout,

  /// The server answered with a non-2xx status.
  httpError,

  /// A 2xx/error body that is not the documented JSON contract.
  malformedResponse,

  /// Private, removed, region-locked or otherwise inaccessible media.
  unavailable,

  /// A valid response that carries no downloadable format.
  noFormats,

  /// Anything else, kept for the log (never rendered raw).
  unknown,
}

/// One analysis failure with a stable user-facing key and optional internal
/// detail. The detail is for `debugPrint` only: it may contain a status code
/// but never a URL or credentials.
class AnalysisException implements Exception {
  final AnalysisFailureType type;
  final int? statusCode;

  /// Backend `error_code` (`unsupported_url`, `no_formats`, ...), kept to make
  /// the log specific without exposing provider internals to the user.
  final String? code;
  final String? detail;

  const AnalysisException(
    this.type, {
    this.statusCode,
    this.code,
    this.detail,
  });

  /// Localization key consumed by `AnalyzeController.error` and rendered by
  /// the Analyzer. Stable strings, not prose.
  String get messageKey {
    switch (type) {
      case AnalysisFailureType.invalidUrl:
        return 'analysisInvalidUrl';
      case AnalysisFailureType.unsupportedPlatform:
        return 'analysisUnsupportedPlatform';
      case AnalysisFailureType.network:
        return 'analysisNetworkError';
      case AnalysisFailureType.timeout:
        return 'analysisTimeout';
      case AnalysisFailureType.httpError:
        return 'analysisServerError';
      case AnalysisFailureType.malformedResponse:
        return 'analysisBadResponse';
      case AnalysisFailureType.unavailable:
        // The backend uses `source_unavailable` when the provider refuses the
        // request (YouTube answers datacenter IPs with "Sign in to confirm
        // you're not a bot"). That is not the same as a private or removed
        // video, and saying so would be a lie.
        return code == 'source_unavailable'
            ? 'analysisSourceBlocked'
            : 'analysisUnavailable';
      case AnalysisFailureType.noFormats:
        return 'analysisNoFormats';
      case AnalysisFailureType.unknown:
        return 'analysisFailed';
    }
  }

  /// Maps one backend error document to the closest typed cause.
  ///
  /// Contract (backend `_error()`): `{success:false, error_code, stage,
  /// detail, request_id}` with status 400/413/422/500/502/507.
  factory AnalysisException.fromBackend(
    int statusCode,
    Map<String, dynamic>? body,
  ) {
    final code = body?['error_code']?.toString();
    final detail = body?['detail']?.toString();
    switch (code) {
      case 'invalid_request':
        return AnalysisException(
          AnalysisFailureType.invalidUrl,
          statusCode: statusCode,
          code: code,
          detail: detail,
        );
      case 'unsupported_url':
        return AnalysisException(
          AnalysisFailureType.unsupportedPlatform,
          statusCode: statusCode,
          code: code,
          detail: detail,
        );
      case 'source_unavailable':
        return AnalysisException(
          AnalysisFailureType.unavailable,
          statusCode: statusCode,
          code: code,
          detail: detail,
        );
      case 'no_formats':
        return AnalysisException(
          AnalysisFailureType.noFormats,
          statusCode: statusCode,
          code: code,
          detail: detail,
        );
    }
    if (statusCode >= 500) {
      return AnalysisException(
        AnalysisFailureType.httpError,
        statusCode: statusCode,
        code: code,
        detail: detail,
      );
    }
    return AnalysisException(
      AnalysisFailureType.unavailable,
      statusCode: statusCode,
      code: code,
      detail: detail,
    );
  }

  @override
  String toString() =>
      'AnalysisException(${type.name}'
      '${statusCode != null ? ', status=$statusCode' : ''}'
      '${code != null ? ', code=$code' : ''}'
      '${detail != null ? ', detail=$detail' : ''})';
}
