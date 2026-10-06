import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/equalizer_service.dart';

String _presetLabel(BuildContext context, String name) {
  final es = Localizations.localeOf(context).languageCode == 'es';
  const mapEs = {
    'Normal': 'Normal',
    'Classical': 'Clásica',
    'Dance': 'Dance',
    'Flat': 'Plano',
    'Folk': 'Folk',
    'Heavy Metal': 'Heavy Metal',
    'Hip Hop': 'Hip Hop',
    'Jazz': 'Jazz',
    'Pop': 'Pop',
    'Rock': 'Rock',
  };
  const mapEn = {
    'Normal': 'Normal',
    'Classical': 'Classical',
    'Dance': 'Dance',
    'Flat': 'Flat',
    'Folk': 'Folk',
    'Heavy Metal': 'Heavy Metal',
    'Hip Hop': 'Hip Hop',
    'Jazz': 'Jazz',
    'Pop': 'Pop',
    'Rock': 'Rock',
  };
  return (es ? mapEs : mapEn)[name] ?? name;
}

String _freqLabel(int hz) {
  if (hz >= 1000) {
    final k = hz / 1000;
    return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}kHz';
  }
  return '${hz}Hz';
}

/// Bottom sheet with the real DSP equalizer: power switch, device presets,
/// per-band sliders, bass boost and loudness.
class EqualizerSheet extends StatelessWidget {
  const EqualizerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Consumer<EqualizerService>(
      builder: (context, eq, _) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.equalizer, color: cs.primary, size: 22),
                    const SizedBox(width: 8),
                    Text(loc.equalizer,
                        style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text(
                      eq.enabled ? loc.equalizerOn : loc.equalizerOff,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                    ),
                    Switch(
                      value: eq.enabled,
                      onChanged: eq.available ? (v) => eq.setEnabled(v) : null,
                    ),
                  ],
                ),
                if (!eq.available) ...[
                  const SizedBox(height: 12),
                  Text(
                    loc.equalizerOff,
                    style:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ] else ...[
                  const SizedBox(height: 4),
                  Text(loc.equalizerPreset,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: eq.presets.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final selected = eq.presetIndex == i;
                        return ChoiceChip(
                          label: Text(_presetLabel(context, eq.presets[i])),
                          selected: selected,
                          onSelected: (_) => eq.setPreset(i),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 190,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(eq.bandCount, (i) {
                        final level = (i < eq.levelsMb.length)
                            ? eq.levelsMb[i]
                            : 0;
                        final freq = (i < eq.freqsHz.length)
                            ? eq.freqsHz[i]
                            : 0;
                        return Column(
                          children: [
                            Text(
                              '${(level / 100).toStringAsFixed(1)}',
                              style: TextStyle(
                                  color: cs.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600),
                            ),
                            Expanded(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Slider(
                                  value: level.toDouble(),
                                  min: eq.minMb.toDouble(),
                                  max: eq.maxMb.toDouble(),
                                  divisions:
                                      ((eq.maxMb - eq.minMb) ~/ 100)
                                          .clamp(1, 60),
                                  onChanged: eq.enabled
                                      ? (v) => eq.setBand(i, v.round())
                                      : null,
                                ),
                              ),
                            ),
                            Text(
                              _freqLabel(freq),
                              style: TextStyle(
                                  color: cs.onSurfaceVariant, fontSize: 11),
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _KnobRow(
                    label: loc.equalizerBass,
                    value: eq.bass,
                    onChanged: eq.enabled ? (v) => eq.setBass(v) : null,
                    cs: cs,
                  ),
                  const SizedBox(height: 8),
                  _KnobRow(
                    label: loc.equalizerLoudness,
                    value: eq.loudness,
                    onChanged:
                        eq.enabled ? (v) => eq.setLoudness(v) : null,
                    cs: cs,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _KnobRow extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int>? onChanged;
  final ColorScheme cs;

  const _KnobRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style:
                  TextStyle(color: cs.onSurface, fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: 0,
            max: 100,
            divisions: 20,
            label: '$value',
            onChanged:
                onChanged == null ? null : (v) => onChanged!(v.round()),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text('$value',
              textAlign: TextAlign.end,
              style: TextStyle(
                  color: cs.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

/// Opens the equalizer sheet from anywhere in the player.
void showEqualizerSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const EqualizerSheet(),
  );
}
