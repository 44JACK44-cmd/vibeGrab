import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/localization/language_provider.dart';
import '../controllers/settings_controller.dart';
import '../../downloads/controllers/downloads_controller.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = context.read<SettingsController>();
      controller.onMaxConcurrentChanged = (value) {
        context.read<DownloadsController>().updateMaxConcurrent(value);
      };
      controller.loadSettings();
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final langProv = context.watch<LanguageProvider>();
    final themeProv = context.watch<ThemeProvider>();
    final cs = Theme.of(context).colorScheme;
    final text1 = Theme.of(context).textTheme.bodyLarge?.color ?? cs.onSurface;
    final text2 = Theme.of(context).textTheme.bodyMedium?.color ?? cs.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: Text(loc.settingsTitle)),
      body: Consumer<SettingsController>(
        builder: (context, controller, _) {
          if (controller.loading || controller.settings == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final s = controller.settings!;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _sectionHeader(loc.sectionAppearance, cs.primary),
              _buildThemeTile(context, themeProv, cs, text1, text2),
              _buildAccentTile(context, themeProv, cs, text1, text2),
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionLanguage, cs.primary),
              _buildLanguageTile(context, loc, langProv, cs, text1, text2),
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionDownloads, cs.primary),
              _buildDownloadDirTile(controller, s.downloadDir, text1, text2, loc, cs),
              _buildSliderTile(
                icon: Icons.speed,
                title: loc.maxConcurrentDownloads,
                value: s.maxConcurrentDownloads.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                label: '${s.maxConcurrentDownloads}',
                onChanged: (v) => controller.updateSetting(maxConcurrentDownloads: v.round()),
                cs: cs,
                text1: text1,
              ),
              _buildSliderTile(
                icon: Icons.sd_storage,
                title: loc.maxFileSize,
                value: s.maxFileSizeMb.toDouble(),
                min: 100,
                max: 4096,
                divisions: 40,
                label: '${s.maxFileSizeMb} MB',
                onChanged: (v) => controller.updateSetting(maxFileSizeMb: v.round()),
                cs: cs,
                text1: text1,
              ),
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionBehavior, cs.primary),
              _buildSwitchTile(
                icon: Icons.open_in_new,
                title: loc.autoOpen,
                subtitle: loc.autoOpenHint,
                value: s.autoOpenAfterDownload,
                onChanged: (v) => controller.updateSetting(autoOpenAfterDownload: v),
                text1: text1,
                text2: text2,
              ),
              _buildSwitchTile(
                icon: Icons.high_quality,
                title: loc.preferBestQuality,
                subtitle: loc.preferBestQualityHint,
                value: s.preferBestQuality,
                onChanged: (v) => controller.updateSetting(preferBestQuality: v),
                text1: text1,
                text2: text2,
              ),
              _buildSwitchTile(
                icon: Icons.info_outline,
                title: loc.saveMetadata,
                subtitle: loc.saveMetadataHint,
                value: s.saveMetadata,
                onChanged: (v) => controller.updateSetting(saveMetadata: v),
                text1: text1,
                text2: text2,
              ),
              const SizedBox(height: 32),
              _sectionHeader(loc.sectionAbout, cs.primary),
              _buildAboutTile(cs, text1, text2),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDownloadDirTile(SettingsController controller, String dir, Color text1, Color text2, AppLocalizations loc, ColorScheme cs) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.folder_outlined, color: text2),
      title: Text(loc.downloadDirectory, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(dir, style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12), overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final path = await controller.pickDownloadDirectory();
        if (path != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.directorySelected)),
          );
        }
      },
    );
  }

  Widget _sectionHeader(String title, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: accent,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildThemeTile(BuildContext context, ThemeProvider themeProv, ColorScheme cs, Color text1, Color text2) {
    final modes = [
      (ThemeMode.dark, 'Dark', Icons.dark_mode),
      (ThemeMode.light, 'Light', Icons.light_mode),
      (ThemeMode.system, 'System', Icons.phone_android),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined, color: text2, size: 22),
              const SizedBox(width: 12),
              Text('Theme', style: TextStyle(color: text1, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: modes.map((m) {
              final isSelected = themeProv.themeMode == m.$1;
              return Expanded(
                child: GestureDetector(
                  onTap: () => themeProv.setThemeMode(m.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected ? cs.primary.withValues(alpha: 0.18) : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected ? cs.primary : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(m.$3, size: 16, color: isSelected ? cs.primary : text2),
                        const SizedBox(width: 6),
                        Text(
                          m.$2,
                          style: TextStyle(
                            color: isSelected ? cs.primary : text2,
                            fontSize: 13,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAccentTile(BuildContext context, ThemeProvider themeProv, ColorScheme cs, Color text1, Color text2) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, color: cs.primary, size: 22),
              const SizedBox(width: 12),
              Text('Accent color', style: TextStyle(color: text1, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: VibeAccent.accents.map((a) {
              final isSelected = themeProv.accent.name == a.name;
              return GestureDetector(
                onTap: () => themeProv.setAccent(a),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: a.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? text1 : Colors.transparent,
                      width: 3,
                    ),
                    boxShadow: isSelected
                        ? [BoxShadow(color: a.color.withValues(alpha: 0.4), blurRadius: 12, spreadRadius: 2)]
                        : [],
                  ),
                  child: isSelected
                      ? Icon(Icons.check, color: a.color.computeLuminance() > 0.5 ? Colors.black : Colors.white, size: 20)
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required Color text1,
    required Color text2,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: text2),
      title: Text(title, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(subtitle, style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12)),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _buildSliderTile({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
    required ColorScheme cs,
    required Color text1,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: cs.onSurfaceVariant),
      title: Text(title, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildLanguageTile(BuildContext context, AppLocalizations loc, LanguageProvider langProv, ColorScheme cs, Color text1, Color text2) {
    final currentMode = langProv.mode;
    String currentLabel;
    switch (currentMode) {
      case 'es':
        currentLabel = loc.languageSpanish;
        break;
      case 'en':
        currentLabel = loc.languageEnglish;
        break;
      default:
        currentLabel = loc.languageAuto;
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.language),
      title: Text(loc.language, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(currentLabel, style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showLanguageDialog(context, loc, langProv),
    );
  }

  Widget _buildAboutTile(ColorScheme cs, Color text1, Color text2) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.apps, color: text2),
      title: Text('VibeGrab', style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text('Version 1.0.0', style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12)),
    );
  }

  void _showLanguageDialog(BuildContext context, AppLocalizations loc, LanguageProvider langProv) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.language),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _languageOption(ctx, langProv, loc.languageAuto, 'auto', langProv.mode == 'auto'),
            _languageOption(ctx, langProv, '${loc.languageSpanish} \u{1F1EA}\u{1F1F8}', 'es', langProv.mode == 'es'),
            _languageOption(ctx, langProv, '${loc.languageEnglish} \u{1F1FA}\u{1F1F8}', 'en', langProv.mode == 'en'),
          ],
        ),
      ),
    );
  }

  Widget _languageOption(BuildContext ctx, LanguageProvider langProv, String label, String mode, bool selected) {
    return RadioListTile<String>(
      value: mode,
      groupValue: langProv.mode,
      onChanged: (value) {
        if (value != null) {
          langProv.setLanguage(value);
        }
        Navigator.pop(ctx);
      },
      title: Text(label, style: const TextStyle(fontSize: 15)),
      contentPadding: EdgeInsets.zero,
    );
  }
}
