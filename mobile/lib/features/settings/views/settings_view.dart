import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/theme/vibe_presets.dart';
import '../../../services/network_diagnostics.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/localization/language_provider.dart';
import '../../../core/constants/api_constants.dart';
import '../../../data/models/app_settings.dart';
import '../../../services/api_service.dart';
import '../../../services/media_engine.dart';
import '../../../services/download_notification_service.dart';
import '../../../services/update_service.dart';
import '../controllers/settings_controller.dart';
import '../../downloads/controllers/downloads_controller.dart';
import '../widgets/update_dialog.dart';
import '../../whats_new/whats_new_service.dart';
import 'trash_view.dart';
import 'vault_view.dart';
import 'status_view.dart';

enum _ServerStatus { checking, up, down }

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  _ServerStatus _serverStatus = _ServerStatus.checking;
  int? _serverLatencyMs;
  bool _serverChecking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = context.read<SettingsController>();
      controller.onMaxConcurrentChanged = (value) {
        context.read<DownloadsController>().updateMaxConcurrent(value);
      };
      controller.loadSettings();
      _checkServer();
    });
  }

  Future<void> _checkServer() async {
    if (_serverChecking) return;
    setState(() {
      _serverChecking = true;
      _serverStatus = _ServerStatus.checking;
    });
    final sw = Stopwatch()..start();
    final ok = await ApiService().checkHealth();
    sw.stop();
    if (!mounted) return;
    setState(() {
      _serverChecking = false;
      _serverStatus = ok ? _ServerStatus.up : _ServerStatus.down;
      _serverLatencyMs = ok ? sw.elapsedMilliseconds : null;
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              // Ordered by how often each group is touched: downloads first,
              // then what the app does with them, then appearance, server and
              // the tools, and the about block last.
              _section(
                title: loc.sectionDownloads,
                icon: Icons.download_rounded,
                cs: cs,
                children: [
                  _buildDownloadDirTile(
                      controller, s.downloadDir, text1, text2, loc, cs),
                  _buildDefaultQualityTile(loc, s, text1, text2),
                  _buildSliderTile(
                    icon: Icons.speed,
                    title: loc.maxConcurrentDownloads,
                    value: s.maxConcurrentDownloads.toDouble(),
                    min: 1,
                    max: 5,
                    divisions: 4,
                    label: '${s.maxConcurrentDownloads}',
                    onChanged: (v) =>
                        controller.updateSetting(maxConcurrentDownloads: v.round()),
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
                    onChanged: (v) =>
                        controller.updateSetting(maxFileSizeMb: v.round()),
                    cs: cs,
                    text1: text1,
                  ),
                  _buildSpeedLimitTile(loc, s, text1, text2),
                ],
              ),
              _section(
                title: loc.sectionBehavior,
                icon: Icons.play_circle_outline,
                cs: cs,
                children: [
                  _buildSwitchTile(
                    icon: Icons.open_in_new,
                    title: loc.autoOpen,
                    subtitle: loc.autoOpenHint,
                    value: s.autoOpenAfterDownload,
                    onChanged: (v) =>
                        controller.updateSetting(autoOpenAfterDownload: v),
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
                ],
              ),
              _section(
                title: loc.sectionNotifications,
                icon: Icons.notifications_outlined,
                cs: cs,
                children: [
                  _buildSwitchTile(
                    icon: Icons.notifications_active_outlined,
                    title: loc.notifyCompleted,
                    subtitle: loc.notifyCompletedHint,
                    value: s.notifyCompleted,
                    onChanged: (v) => controller.updateSetting(notifyCompleted: v),
                    text1: text1,
                    text2: text2,
                  ),
                  _buildSwitchTile(
                    icon: Icons.error_outline,
                    title: loc.notifyErrors,
                    subtitle: loc.notifyErrorsHint,
                    value: s.notifyErrors,
                    onChanged: (v) => controller.updateSetting(notifyErrors: v),
                    text1: text1,
                    text2: text2,
                  ),
                  _buildSwitchTile(
                    icon: Icons.volume_up_outlined,
                    title: loc.notifySound,
                    subtitle: loc.notifySoundHint,
                    value: s.notifySound,
                    onChanged: (v) {
                      controller.updateSetting(notifySound: v);
                      DownloadNotificationService().setResultsSound(v);
                    },
                    text1: text1,
                    text2: text2,
                  ),
                ],
              ),
              _section(
                title: loc.sectionAppearance,
                icon: Icons.palette_outlined,
                cs: cs,
                children: [
                  _buildThemeTile(context, themeProv, cs, text1, text2),
                  _buildAccentTile(context, themeProv, cs, text1, text2),
                  _buildLanguageTile(context, loc, langProv, cs, text1, text2),
                ],
              ),
              _section(
                title: loc.sectionServer,
                icon: Icons.dns_outlined,
                cs: cs,
                children: [
                  _buildBackendUrlTile(context, loc, text1, text2),
                  _buildServerStatusTile(loc, cs, text1, text2),
                ],
              ),
              _section(
                title: loc.sectionTools,
                icon: Icons.build_outlined,
                cs: cs,
                children: [
                  _buildNavTile(
                    icon: Icons.delete_sweep_outlined,
                    title: loc.trash,
                    subtitle: loc.trashHint,
                    text1: text1,
                    text2: text2,
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const TrashView())),
                  ),
                  _buildNavTile(
                    icon: Icons.lock_outline,
                    title: loc.vault,
                    subtitle: loc.vaultHint,
                    text1: text1,
                    text2: text2,
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const VaultView())),
                  ),
                  _buildNavTile(
                    icon: Icons.perm_media_outlined,
                    title: loc.statusSaver,
                    subtitle: loc.statusSaverHint,
                    text1: text1,
                    text2: text2,
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const StatusView())),
                  ),
                ],
              ),
              _section(
                title: loc.sectionAbout,
                icon: Icons.info_outline,
                cs: cs,
                children: [
                  _buildAboutTile(context, cs, text1, text2),
                  _buildWhatsNewTile(context, cs, text1, text2),
                  _buildMediaSessionTile(context, cs, text1, text2),
                  _buildNetTestTile(context, cs, text1, text2),
                ],
              ),
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
        if (path != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.directorySelected)),
          );
        }
      },
    );
  }

  Widget _buildBackendUrlTile(BuildContext context, AppLocalizations loc, Color text1, Color text2) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.dns_outlined, color: text2),
      title: Text(loc.backendUrl, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(
        ApiConfig.baseUrl,
        style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showBackendUrlDialog(context, loc),
    );
  }

  Future<void> _showBackendUrlDialog(BuildContext context, AppLocalizations loc) async {
    final ctrl = TextEditingController(text: ApiConfig.baseUrl);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.backendUrl),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            hintText: loc.backendUrlPlaceholder,
            helperText: loc.backendUrlHint,
            helperMaxLines: 4,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _saveBackendUrl(ctx, ctrl.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () => _saveBackendUrl(ctx, ctrl.text),
            child: Text(loc.save),
          ),
        ],
      ),
    );
    ctrl.dispose();
  }

  Future<void> _saveBackendUrl(BuildContext dialogContext, String raw) async {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    await ApiConfig.setBaseUrl(url);
    if (mounted) {
      setState(() {});
    }
    if (dialogContext.mounted) {
      Navigator.pop(dialogContext);
    }
  }

  String _qualityLabel(AppLocalizations loc, String quality) {
    switch (quality) {
      case 'best':
        return loc.qualityBest;
      case 'audio':
        return loc.qualityAudioOnly;
      default:
        return quality;
    }
  }

  Widget _buildDefaultQualityTile(AppLocalizations loc, AppSettings s, Color text1, Color text2) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.high_quality, color: text2),
      title: Text(loc.defaultQuality, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(
        _qualityLabel(loc, s.defaultQuality),
        style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showQualityDialog(loc, s.defaultQuality),
    );
  }

  void _showQualityDialog(AppLocalizations loc, String current) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.defaultQuality),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (v) {
            if (v != null) {
              context.read<SettingsController>().updateSetting(defaultQuality: v);
            }
            Navigator.pop(ctx);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _qualityOption(loc, 'best', loc.qualityBest),
              _qualityOption(loc, '1080p', '1080p'),
              _qualityOption(loc, '720p', '720p'),
              _qualityOption(loc, '480p', '480p'),
              _qualityOption(loc, 'audio', loc.qualityAudioOnly),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
        ],
      ),
    );
  }

  Widget _qualityOption(AppLocalizations loc, String value, String label) {
    return RadioListTile<String>(
      value: value,
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 15)),
      contentPadding: EdgeInsets.zero,
    );
  }

  String _speedLabel(AppLocalizations loc, int kbps) {
    return kbps == 0 ? loc.speedUnlimited : '$kbps KB/s';
  }

  Widget _buildSpeedLimitTile(AppLocalizations loc, AppSettings s, Color text1, Color text2) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.data_usage, color: text2),
      title: Text(loc.speedLimit, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(
        _speedLabel(loc, s.speedLimitKbps),
        style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showSpeedDialog(loc, s.speedLimitKbps),
    );
  }

  void _showSpeedDialog(AppLocalizations loc, int current) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.speedLimit),
        content: RadioGroup<int>(
          groupValue: current,
          onChanged: (v) {
            if (v != null) {
              context.read<SettingsController>().updateSetting(speedLimitKbps: v);
            }
            Navigator.pop(ctx);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _speedOption(loc, 0),
              _speedOption(loc, 100),
              _speedOption(loc, 300),
              _speedOption(loc, 500),
              _speedOption(loc, 1000),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
        ],
      ),
    );
  }

  Widget _speedOption(AppLocalizations loc, int value) {
    return RadioListTile<int>(
      value: value,
      dense: true,
      title: Text(_speedLabel(loc, value), style: const TextStyle(fontSize: 15)),
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildServerStatusTile(
      AppLocalizations loc, ColorScheme cs, Color text1, Color text2) {
    IconData icon;
    Color color;
    String subtitle;
    switch (_serverStatus) {
      case _ServerStatus.checking:
        icon = Icons.sync;
        color = Colors.grey;
        subtitle = loc.serverChecking;
      case _ServerStatus.up:
        icon = Icons.cloud_done;
        color = const Color(0xFF2ECC71);
        subtitle = _serverLatencyMs != null
            ? '${loc.serverOnline} • $_serverLatencyMs ms'
            : loc.serverOnline;
      case _ServerStatus.down:
        icon = Icons.cloud_off;
        color = const Color(0xFFE74C3C);
        subtitle = loc.serverOffline;
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(loc.serverStatus, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12),
      ),
      trailing: IconButton(
        icon: Icon(Icons.refresh, color: text2, size: 20),
        onPressed: _serverChecking ? null : _checkServer,
      ),
      onTap: _serverChecking ? null : _checkServer,
    );
  }

  /// A settings group: a labelled card. Grouping the tiles this way makes the
  /// screen read as a handful of blocks instead of one long list, and keeps
  /// every tile and its behaviour untouched.
  Widget _section({
    required String title,
    required IconData icon,
    required ColorScheme cs,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(title, icon, cs),
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  /// Row tile that opens another screen (trash, vault, statuses).
  Widget _buildNavTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color text1,
    required Color text2,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: text2),
      title: Text(title, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _sectionHeader(String title, IconData icon, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: cs.primary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

Widget _buildThemeTile(BuildContext context, ThemeProvider themeProv, ColorScheme cs, Color text1, Color text2) {
final loc = AppLocalizations.of(context);
final modes = [
      (ThemeMode.dark, loc.themeDark, Icons.dark_mode),
      (ThemeMode.light, loc.themeLight, Icons.light_mode),
      (ThemeMode.system, loc.themeSystem, Icons.phone_android),
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
              Text(loc.theme, style: TextStyle(color: text1, fontSize: 15)),
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
          const SizedBox(height: 8),
          // Theme presets: Dub-style skins (classic, midnight, emerald...).
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: VibePreset.presets.map((p) {
              final selected = themeProv.preset.id == p.id;
              return GestureDetector(
                onTap: () => themeProv.setPreset(p),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 104,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? cs.primary.withValues(alpha: 0.18)
                        : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? cs.primary : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [p.accent, p.background],
                          ),
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        loc.value(p.labelKey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? cs.primary : text2,
                          fontSize: 11,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ],
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
final loc = AppLocalizations.of(context);
return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, color: cs.primary, size: 22),
              const SizedBox(width: 12),
              Text(loc.accentColor, style: TextStyle(color: text1, fontSize: 15)),
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

  Widget _buildAboutTile(BuildContext context, ColorScheme cs, Color text1, Color text2) {
    return FutureBuilder<({String version, int build})>(
      future: UpdateService.currentVersion(),
      builder: (context, snap) {
        final version = snap.data?.version ?? '';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.apps, color: text2),
          title: Text('VibeGrab', style: TextStyle(color: text1, fontSize: 15)),
          subtitle: Text(
            version.isEmpty ? 'VibeGrab' : '${AppLocalizations.of(context).aboutVersion} $version',
            style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12),
          ),
          trailing: const Icon(Icons.system_update_outlined, size: 20),
          onTap: () => UpdateDialog.checkAndShow(context, manual: true),
        );
      },
    );
  }

  Widget _buildWhatsNewTile(BuildContext context, ColorScheme cs, Color text1, Color text2) {
    final loc = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.auto_awesome, color: text2),
      title:
          Text(loc.whatsNewViewNotes, style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(
        loc.whatsNewSubtitle,
        style: TextStyle(color: text2.withValues(alpha: 0.7), fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => WhatsNewService.showLatest(context),
    );
  }

  Widget _buildMediaSessionTile(BuildContext context, ColorScheme cs, Color text1, Color text2) {
    final loc = AppLocalizations.of(context);
    final engine = context.watch<MediaEngine>();
    final st = engine.mediaSessionStatus;
    final notifOk =
        engine.notificationsEnabledNative ?? engine.notificationPermission;
    final err = engine.lastSessionError;

    final notRun = loc.sessionNotStarted;
    final connecting = loc.sessionConnecting;
    String base;
    if (st == 'ok') {
      base = loc.sessionOk;
    } else if (st == 'running') {
      base = connecting;
    } else if (st == 'not_run') {
      base = notRun;
    } else {
      base = st;
    }

    final String label;
    final Color color;
    if (err != null) {
      final short = err.length > 140 ? '${err.substring(0, 140)}…' : err;
      label = loc.sessionSystemError(short);
      color = Colors.redAccent;
    } else if (engine.missingIconDrawables != null) {
      label = loc.sessionIconsMissing(engine.missingIconDrawables ?? '');
      color = Colors.redAccent;
    } else if (notifOk == false) {
      label = '$base · ${loc.sessionNotificationsBlocked}';
      color = Colors.redAccent;
    } else if (st == 'ok') {
      label = notifOk == true
          ? '$base · ${loc.sessionNotificationsOk}'
          : base;
      color = Colors.green;
    } else if (st == 'running') {
      label = base;
      color = Colors.orange;
    } else {
      label = base;
      color = Colors.redAccent;
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.music_note, color: color),
      title: Text(AppLocalizations.of(context).mediaSessionLabel,
          style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(
        label,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 12),
      ),
      trailing: Icon(Icons.refresh, size: 18, color: color.withValues(alpha: 0.7)),
      onTap: () {
        if (notifOk == false && err == null) {
          engine.openNotificationSettings();
        } else {
          engine.initAudioService(force: true);
        }
      },
    );
  }

  /// Network self-test: measures every link of the playback chain on
  /// THIS phone so failures stop being guesswork.
  Widget _buildNetTestTile(
      BuildContext context, ColorScheme cs, Color text1, Color text2) {
    final loc = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.network_check, color: text2),
      title: Text(loc.netTest,
          style: TextStyle(color: text1, fontSize: 15)),
      subtitle: Text(loc.netTestHint,
          style: TextStyle(
              color: text2.withValues(alpha: 0.7), fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => _runNetTest(context, loc, cs),
    );
  }

  Future<void> _runNetTest(
      BuildContext context, AppLocalizations loc, ColorScheme cs) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(loc.netTestTitle),
        content: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(loc.netTestRunning)),
          ],
        ),
      ),
    );
    List<DiagResult> results = const [];
    try {
      results = await NetworkDiagnostics.run();
    } catch (_) {}
    if (!context.mounted) return;
    Navigator.pop(context); // close progress
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.netTestTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: results
                .map((r) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            r.ok ? Icons.check_circle : Icons.cancel,
                            color:
                                r.ok ? Colors.green : Colors.redAccent,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_netLabel(loc, r.key)} · ${r.ms} ms',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13),
                                ),
                                Text(
                                  r.detail,
                                  style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                      fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.close),
          ),
        ],
      ),
    );
  }

  String _netLabel(AppLocalizations loc, String key) {
    switch (key) {
      case 'backend':
        return loc.netBackend;
      case 'stream':
        return loc.netStream;
      case 'manifest':
        return loc.netManifest;
      case 'direct':
        return loc.netDirect;
      default:
        return key;
    }
  }

  void _showLanguageDialog(BuildContext context, AppLocalizations loc, LanguageProvider langProv) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.language),
        content: RadioGroup<String>(
          groupValue: langProv.mode,
          onChanged: (value) {
            if (value != null) {
              langProv.setLanguage(value);
            }
            Navigator.pop(ctx);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _languageOption(loc.languageAuto, 'auto'),
              _languageOption('${loc.languageSpanish} \u{1F1EA}\u{1F1F8}', 'es'),
              _languageOption('${loc.languageEnglish} \u{1F1FA}\u{1F1F8}', 'en'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _languageOption(String label, String mode) {
    return RadioListTile<String>(
      value: mode,
      title: Text(label, style: const TextStyle(fontSize: 15)),
      contentPadding: EdgeInsets.zero,
    );
  }
}
