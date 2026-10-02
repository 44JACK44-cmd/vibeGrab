import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/localization/language_provider.dart';
import '../../../core/constants/api_constants.dart';
import '../../../data/models/app_settings.dart';
import '../../../services/api_service.dart';
import '../../../services/download_notification_service.dart';
import '../../../services/update_service.dart';
import '../controllers/settings_controller.dart';
import '../../downloads/controllers/downloads_controller.dart';
import '../widgets/update_dialog.dart';
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
            padding: const EdgeInsets.all(16),
            children: [
              _sectionHeader(loc.sectionGeneral, cs.primary),
              _buildThemeTile(context, themeProv, cs, text1, text2),
              _buildAccentTile(context, themeProv, cs, text1, text2),
              _buildLanguageTile(context, loc, langProv, cs, text1, text2),
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionDownloads, cs.primary),
              _buildDownloadDirTile(controller, s.downloadDir, text1, text2, loc, cs),
              _buildDefaultQualityTile(loc, s, text1, text2),
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
              _buildSpeedLimitTile(loc, s, text1, text2),
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
                icon: Icons.info_outline,
                title: loc.saveMetadata,
                subtitle: loc.saveMetadataHint,
                value: s.saveMetadata,
                onChanged: (v) => controller.updateSetting(saveMetadata: v),
                text1: text1,
                text2: text2,
              ),
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionNotifications, cs.primary),
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
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionServer, cs.primary),
              _buildBackendUrlTile(context, loc, text1, text2),
              _buildServerStatusTile(loc, cs, text1, text2),
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionTools, cs.primary),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_sweep_outlined, color: text2),
                title: Text(loc.trash,
                    style: TextStyle(color: text1, fontSize: 15)),
                subtitle: Text(loc.trashHint,
                    style: TextStyle(
                        color: text2.withValues(alpha: 0.7), fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const TrashView())),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.lock_outline, color: text2),
                title: Text(loc.vault,
                    style: TextStyle(color: text1, fontSize: 15)),
                subtitle: Text(loc.vaultHint,
                    style: TextStyle(
                        color: text2.withValues(alpha: 0.7), fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const VaultView())),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.perm_media_outlined, color: text2),
                title: Text(loc.statusSaver,
                    style: TextStyle(color: text1, fontSize: 15)),
                subtitle: Text(loc.statusSaverHint,
                    style: TextStyle(
                        color: text2.withValues(alpha: 0.7), fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const StatusView())),
              ),
              const SizedBox(height: 24),
              _sectionHeader(loc.sectionAbout, cs.primary),
              _buildAboutTile(context, cs, text1, text2),
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
            hintText: 'https://vibegrab-api.onrender.com',
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _qualityOption(ctx, loc, 'best', loc.qualityBest, current),
            _qualityOption(ctx, loc, '1080p', '1080p', current),
            _qualityOption(ctx, loc, '720p', '720p', current),
            _qualityOption(ctx, loc, '480p', '480p', current),
            _qualityOption(ctx, loc, 'audio', loc.qualityAudioOnly, current),
          ],
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

  Widget _qualityOption(
      BuildContext ctx, AppLocalizations loc, String value, String label, String current) {
    return RadioListTile<String>(
      value: value,
      groupValue: current,
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 15)),
      contentPadding: EdgeInsets.zero,
      onChanged: (v) {
        if (v != null) {
          context.read<SettingsController>().updateSetting(defaultQuality: v);
        }
        Navigator.pop(ctx);
      },
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _speedOption(ctx, loc, 0, current),
            _speedOption(ctx, loc, 100, current),
            _speedOption(ctx, loc, 300, current),
            _speedOption(ctx, loc, 500, current),
            _speedOption(ctx, loc, 1000, current),
          ],
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

  Widget _speedOption(BuildContext ctx, AppLocalizations loc, int value, int current) {
    return RadioListTile<int>(
      value: value,
      groupValue: current,
      dense: true,
      title: Text(_speedLabel(loc, value), style: const TextStyle(fontSize: 15)),
      contentPadding: EdgeInsets.zero,
      onChanged: (v) {
        if (v != null) {
          context.read<SettingsController>().updateSetting(speedLimitKbps: v);
        }
        Navigator.pop(ctx);
      },
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
