import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkStatus { offline, online }

class ConnectivityService {
  static ConnectivityService? _instance;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  final StreamController<NetworkStatus> _controller =
      StreamController<NetworkStatus>.broadcast();
  NetworkStatus _status = NetworkStatus.online;
  bool _hasInternet = true;

  ConnectivityService._();

  static ConnectivityService get instance {
    _instance ??= ConnectivityService._();
    return _instance!;
  }

  NetworkStatus get status => _status;
  bool get hasInternet => _hasInternet;
  bool get hasBackend => false;
  bool get isOnline => _hasInternet;
  bool get isOffline => !_hasInternet;
  bool get isBackendAvailable => false;
  Stream<NetworkStatus> get onStatusChanged => _controller.stream;

  void init() {
    _subscription = _connectivity.onConnectivityChanged.listen((results) async {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      _hasInternet = hasConnection;
      _updateStatus(hasConnection ? NetworkStatus.online : NetworkStatus.offline);
    });
  }

  void _updateStatus(NetworkStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      _controller.add(newStatus);
    }
  }

  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}
