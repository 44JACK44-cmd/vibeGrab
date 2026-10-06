import 'dart:async';
import 'package:flutter/material.dart';

/// Visibility + transient hint state for the pro video controls.
///
/// One instance per video screen. Any interaction calls [poke] (restart the
/// auto-hide timer); tapping the video calls [toggle]. The timer only hides
/// when [canHide] (playing) is true, like professional players.
class VideoControlsController extends ChangeNotifier {
  bool visible = true;
  String? hintText;
  IconData? hintIcon;
  Timer? _timer;
  bool Function()? canHide;

  void show() {
    visible = true;
    _restart();
    notifyListeners();
  }

  void hide() {
    _timer?.cancel();
    if (!visible) return;
    visible = false;
    hintText = null;
    notifyListeners();
  }

  void toggle() {
    if (visible) {
      hide();
    } else {
      show();
    }
  }

  /// Keep visible and restart the auto-hide countdown.
  void poke() {
    if (!visible) return;
    _restart();
  }

  void flashHint(String text, IconData icon) {
    hintText = text;
    hintIcon = icon;
    notifyListeners();
  }

  void clearHint() {
    hintText = null;
    notifyListeners();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), () {
      if (canHide == null || canHide!()) hide();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
