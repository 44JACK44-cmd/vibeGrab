import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/media_state.dart';
import '../../../services/media_engine.dart';

/// The single global playback-mode button (normal -> repeat-all ->
/// repeat-one -> shuffle). Used by the player, the mini player and every
/// other surface so the mode is always the same everywhere.
class PlayModeButton extends StatelessWidget {
  final double size;
  final Color? activeColor;
  final Color? inactiveColor;

  const PlayModeButton({
    super.key,
    this.size = 26,
    this.activeColor,
    this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<MediaEngine>();
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final shuffle = engine.state.isShuffle;
    final mode = engine.state.repeatMode;

    late final IconData icon;
    late final String tip;
    late final bool active;
    if (shuffle) {
      icon = Icons.shuffle;
      tip = loc.modeShuffle;
      active = true;
    } else {
      switch (mode) {
        case PlayerRepeatMode.one:
          icon = Icons.repeat_one;
          tip = loc.modeRepeatOne;
          active = true;
          break;
        case PlayerRepeatMode.all:
          icon = Icons.repeat;
          tip = loc.modeRepeatAll;
          active = true;
          break;
        case PlayerRepeatMode.none:
          icon = Icons.repeat;
          tip = loc.modeNormal;
          active = false;
          break;
      }
    }

    return IconButton(
      tooltip: tip,
      icon: Icon(
        icon,
        size: size,
        color: active
            ? (activeColor ?? cs.primary)
            : (inactiveColor ?? cs.onSurface),
      ),
      onPressed: () => engine.cyclePlayMode(),
    );
  }
}
