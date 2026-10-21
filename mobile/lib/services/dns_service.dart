import 'package:flutter/services.dart';

/// Read-only view of the DNS configuration Android is using.
///
/// Scope, stated explicitly because it cannot be changed from Dart:
/// * `dart:io` sockets (API calls, downloads) use the Android system resolver.
/// * The in-app browser is a WebView; it uses Chromium's resolver, which also
///   follows the system's Private DNS setting. VibeGrab cannot install a
///   per-app DoH/DoT resolver for WebView without a VPN/Cronet service.
/// * Android Private DNS (DoT) is configured by the user in system settings.
class DnsStatus {
  final String mode;
  final String hostname;
  final List<String> servers;
  final bool supported;

  const DnsStatus({
    required this.mode,
    required this.hostname,
    required this.servers,
    required this.supported,
  });

  static const unknown = DnsStatus(
    mode: 'unknown',
    hostname: '',
    servers: [],
    supported: false,
  );

  bool get privateDnsEnabled => mode == 'hostname' || mode == 'opportunistic';

  String get privateDnsLabel {
    switch (mode) {
      case 'off':
        return 'Off';
      case 'opportunistic':
        return 'Automatic (opportunistic)';
      case 'hostname':
        return hostname.isEmpty ? 'On' : hostname;
      default:
        return 'Unknown';
    }
  }
}

class DnsService {
  static const _channel = MethodChannel('com.example.vibegrab/app');

  static Future<DnsStatus> getStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getDnsStatus',
      );
      if (raw == null) return DnsStatus.unknown;
      final servers = <String>[];
      final rawServers = raw['servers'];
      if (rawServers is List) {
        for (final value in rawServers) {
          if (value is String && value.isNotEmpty) servers.add(value);
        }
      }
      return DnsStatus(
        mode: (raw['mode'] as String?) ?? 'unknown',
        hostname: (raw['hostname'] as String?) ?? '',
        servers: servers,
        supported: true,
      );
    } catch (_) {
      return DnsStatus.unknown;
    }
  }

  static Future<bool> openPrivateDnsSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openPrivateDnsSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }
}
