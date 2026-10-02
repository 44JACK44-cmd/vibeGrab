import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/library_file.dart';
import '../../../services/media_engine.dart';
import '../../../services/storage_service.dart';
import '../../../services/vault_service.dart';
import '../../media_player/views/video_player_view.dart';

enum _VaultPhase { loading, createPin, gate, unlocked }

class VaultView extends StatefulWidget {
  const VaultView({super.key});

  @override
  State<VaultView> createState() => _VaultViewState();
}

class _VaultViewState extends State<VaultView> {
  _VaultPhase _phase = _VaultPhase.loading;
  List<VaultFile> _files = [];
  final _pinController = TextEditingController();
  String? _errorText;
  int _lockSeconds = 0;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final service = VaultService.instance;
    if (!await service.isPinSet) {
      if (mounted) setState(() => _phase = _VaultPhase.createPin);
      return;
    }
    if (await service.isLocked) {
      final left = await service.lockSecondsLeft;
      _startLockTimer(left);
      if (mounted) setState(() => _phase = _VaultPhase.gate);
      return;
    }
    if (mounted) setState(() => _phase = _VaultPhase.gate);
  }

  void _startLockTimer(int seconds) {
    _lockSeconds = seconds;
    _lockTimer?.cancel();
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_lockSeconds <= 1) {
        t.cancel();
        _lockTimer = null;
        if (mounted) {
          setState(() {
            _lockSeconds = 0;
            _errorText = null;
          });
        }
      } else if (mounted) {
        setState(() => _lockSeconds--);
      }
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _loadFiles() async {
    final files = await VaultService.instance.list();
    if (!mounted) return;
    setState(() => _files = files);
  }

  Future<void> _verify(String pin, AppLocalizations loc) async {
    final service = VaultService.instance;
    if (pin.length != 4) return;
    if (await service.isLocked) {
      setState(() => _errorText = loc.pinLocked);
      return;
    }
    final ok = await service.verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _phase = _VaultPhase.unlocked;
        _errorText = null;
        _pinController.clear();
      });
      _loadFiles();
    } else {
      final locked = await service.isLocked;
      setState(() {
        _errorText = locked ? loc.pinLocked : loc.wrongPin;
        _pinController.clear();
      });
      if (locked) {
        final left = await service.lockSecondsLeft;
        _startLockTimer(left);
      }
    }
  }

  Future<void> _showCreatePinDialog(AppLocalizations loc) async {
    final first = TextEditingController();
    final second = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.createPin),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: first,
              autofocus: true,
              obscureText: true,
              maxLength: 4,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: InputDecoration(
                hintText: loc.createPinHint,
                counterText: '',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: second,
              obscureText: true,
              maxLength: 4,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: InputDecoration(
                hintText: loc.confirmPin,
                counterText: '',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () async {
              if (first.text.length != 4) {
                _snack(loc.createPinHint);
                return;
              }
              if (first.text != second.text) {
                _snack(loc.pinMismatch);
                return;
              }
              await VaultService.instance.setPin(first.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                setState(() => _phase = _VaultPhase.unlocked);
                _loadFiles();
              }
            },
            child: Text(loc.createPin),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(VaultFile vf, AppLocalizations loc) async {
    final restored = await VaultService.instance.restoreFromVault(vf.name);
    if (restored != null) _snack(loc.trashRestored);
    _loadFiles();
  }

  void _confirmDelete(VaultFile vf, AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.delete),
        content: Text(vf.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await VaultService.instance.deleteFromVault(vf.name);
              _loadFiles();
            },
            child: Text(loc.delete, style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  void _play(VaultFile vf) {
    final engine = context.read<MediaEngine>();
    final file = VaultService.instance.toLibraryFile(vf);
    if (vf.isVideo) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChangeNotifierProvider.value(
            value: engine,
            child: VideoPlayerView(file: file),
          ),
        ),
      );
    } else {
      engine.playFile(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(loc.vault)),
      body: switch (_phase) {
        _VaultPhase.loading => const Center(child: CircularProgressIndicator()),
        _VaultPhase.createPin => _buildCreatePrompt(loc, cs),
        _VaultPhase.gate => _buildGate(loc, cs),
        _VaultPhase.unlocked => _buildList(loc, cs),
      },
    );
  }

  Widget _buildCreatePrompt(AppLocalizations loc, ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline,
                size: 72, color: cs.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(
              loc.vault,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              loc.createPinHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _showCreatePinDialog(loc),
              icon: const Icon(Icons.password),
              label: Text(loc.createPin),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGate(AppLocalizations loc, ColorScheme cs) {
    final lockedOut = _lockSeconds > 0;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock,
                size: 72, color: cs.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(
              loc.enterPin,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 220,
              child: TextField(
                controller: _pinController,
                obscureText: true,
                autofocus: true,
                maxLength: 4,
                enabled: !lockedOut,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 12),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••',
                  border: const OutlineInputBorder(),
                  errorText: _errorText,
                ),
                onChanged: (v) {
                  if (v.length == 4) _verify(v, loc);
                },
                onSubmitted: (v) => _verify(v, loc),
              ),
            ),
            const SizedBox(height: 16),
            if (lockedOut)
              Text(
                '$_lockSeconds s',
                style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
              )
            else
              FilledButton(
                onPressed: () => _verify(_pinController.text, loc),
                child: Text(loc.unlock),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(AppLocalizations loc, ColorScheme cs) {
    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline,
                size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              loc.vaultEmpty,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final vf = _files[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                vf.isVideo ? Icons.videocam_outlined : Icons.audiotrack_outlined,
                color: cs.primary,
                size: 22,
              ),
            ),
            title: Text(
              vf.name.contains('.')
                  ? vf.name.substring(0, vf.name.lastIndexOf('.'))
                  : vf.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              StorageService.formatSize(vf.size),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            onTap: () => _play(vf),
            trailing: PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant, size: 20),
              onSelected: (value) {
                if (value == 'restore') _restore(vf, loc);
                if (value == 'delete') _confirmDelete(vf, loc);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'restore',
                  child: Row(
                    children: [
                      const Icon(Icons.restore, size: 18),
                      const SizedBox(width: 10),
                      Text(loc.restore),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete, size: 18, color: AppColors.error),
                      const SizedBox(width: 10),
                      Text(loc.delete,
                          style: const TextStyle(color: AppColors.error)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
