import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_provider.dart';
import 'core/localization/app_localizations.dart';
import 'core/localization/language_provider.dart';
import 'core/constants/api_constants.dart';
import 'services/storage_service.dart';
import 'services/connectivity_service.dart';
import 'services/share_intent_handler.dart';
import 'services/download_notification_service.dart';
import 'services/download_persistence_service.dart';
import 'services/media_engine.dart';
import 'services/media_metadata_service.dart';
import 'services/equalizer_service.dart';
import 'services/pip_service.dart';
import 'services/local_extraction_service.dart';
import 'services/local_download_service.dart';
import 'services/trash_service.dart';
import 'services/api_service.dart';
import 'features/analyzer/controllers/analyze_controller.dart';
import 'features/downloads/controllers/downloads_controller.dart';
import 'features/explore/controllers/explore_controller.dart';
import 'features/library/controllers/library_controller.dart';
import 'features/settings/controllers/settings_controller.dart';
import 'features/analyzer/views/analyzer_view.dart';
import 'features/downloads/views/downloads_view.dart';
import 'features/explore/views/explore_view.dart';
import 'features/library/views/library_view.dart';
import 'features/settings/views/settings_view.dart';
import 'features/media_player/widgets/mini_player.dart';
import 'features/settings/widgets/update_dialog.dart';
import 'features/share/controllers/shared_download_controller.dart';
import 'features/share/widgets/share_overlay_page.dart';
import 'features/share/widgets/shared_download_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  ));

  try {
    final languageProvider = LanguageProvider();
    await languageProvider.init();

    final themeProvider = ThemeProvider();
    await themeProvider.init();

    final metaService = MediaMetadataService();
    await metaService.init();

    await StorageService.instance.init();

    await ApiConfig.init();

    Future.delayed(const Duration(milliseconds: 400), () {
      ApiService().checkHealth().then((ok) {
        debugPrint('[Main] Backend warmup: $ok');
      }).catchError((e) {
        debugPrint('[Main] Backend warmup failed: $e');
        return false;
      });
    });

    TrashService.instance.purgeExpired().catchError((_) {});

    ConnectivityService.instance.init();

    await ShareIntentHandler().init();

    final notifService = DownloadNotificationService();
    notifService.init();

    FlutterError.onError = (details) {
      debugPrint('Flutter Error: ${details.exception}');
      debugPrint('${details.stack}');
    };

    runApp(VibeGrabApp(
      languageProvider: languageProvider,
      themeProvider: themeProvider,
      metaService: metaService,
    ));
  } catch (e, st) {
    debugPrint('INIT ERROR: $e');
    debugPrint('$st');
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Error: $e', style: const TextStyle(color: Colors.white)),
        ),
      ),
      theme: ThemeData.dark(),
    ));
  }
}

class VibeGrabApp extends StatelessWidget {
  final LanguageProvider languageProvider;
  final ThemeProvider themeProvider;
  final MediaMetadataService metaService;

  const VibeGrabApp({
    super.key,
    required this.languageProvider,
    required this.themeProvider,
    required this.metaService,
  });

  @override
  Widget build(BuildContext context) {
    final extractionService = LocalExtractionService();
    final downloadService = LocalDownloadService();
    final notifService = DownloadNotificationService();
    final persistence = DownloadPersistenceService();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: languageProvider),
        ChangeNotifierProvider.value(value: themeProvider),
        Provider<LocalExtractionService>.value(value: extractionService),
        Provider<LocalDownloadService>.value(value: downloadService),
        Provider<DownloadNotificationService>.value(value: notifService),
        Provider<DownloadPersistenceService>.value(value: persistence),
        ChangeNotifierProvider.value(value: metaService),
        ChangeNotifierProvider.value(value: EqualizerService.instance),
        ChangeNotifierProvider(create: (_) => AnalyzeController()),
        ChangeNotifierProvider(
          create: (_) => DownloadsController(
            downloadService: downloadService,
            notifService: notifService,
            persistence: persistence,
          ),
        ),
        ChangeNotifierProvider(create: (_) => ExploreController()),
        ChangeNotifierProvider(create: (_) => LibraryController()),
        ChangeNotifierProvider(create: (_) => SettingsController()),
        ChangeNotifierProvider(create: (_) => SharedDownloadController()),
        ChangeNotifierProvider(create: (_) => MediaEngine()),
      ],
      child: Consumer2<LanguageProvider, ThemeProvider>(
        builder: (context, langProv, themeProv, _) {
          return ListenableBuilder(
            listenable: ShareIntentHandler().overlayMode,
            builder: (context, _) {
              final shareOverlay = ShareIntentHandler().overlayMode.value;
              return MaterialApp(
                title: 'VibeGrab',
                themeMode: themeProv.themeMode,
                theme: AppTheme.lightTheme(themeProv.accent.color),
                darkTheme: AppTheme.presetTheme(
                    themeProv.preset, themeProv.accent.color),
                debugShowCheckedModeBanner: false,
                locale: langProv.locale,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: shareOverlay
                    ? const ShareOverlayPage()
                    : const MainShell(),
              );
            },
          );
        },
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _currentIndex = 0;
  StreamSubscription<String>? _shareSubscription;
  StreamSubscription<NotificationAction>? _notifActionSubscription;

  void _navigateToTab(int index) {
    if (mounted) {
      setState(() => _currentIndex = index);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _shareSubscription = ShareIntentHandler().onUrlReceived.listen((url) {
      if (!mounted) return;
      if (url.isEmpty) return;
      if (ShareIntentHandler().overlayMode.value) return;
      final sharedController = context.read<SharedDownloadController>();
      ShareIntentHandler().consumePendingUrl();
      sharedController.analyzeUrl(url);
      SharedDownloadSheet.show(context, sharedController);
    });

    _notifActionSubscription = DownloadNotificationService().onAction.listen((action) {
      if (!mounted) return;
      final dl = context.read<DownloadsController>();
      switch (action.type) {
        case NotificationActionType.cancel:
          if (action.taskId != null) dl.cancelTask(action.taskId!);
          break;
        case NotificationActionType.retry:
          if (action.taskId != null) dl.retryTask(action.taskId!);
          break;
        case NotificationActionType.openLibrary:
          setState(() => _currentIndex = 3);
          break;
      }
    });

    PiPService.onPiPChanged.listen((isInPip) {
      final engine = context.read<MediaEngine>();
      if (isInPip) {
        engine.onPiPEntered();
      } else {
        engine.onPiPExited();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 500), () {
if (!mounted) return;
context.read<MediaEngine>().loadPlayMode();
context.read<MediaEngine>().initAudioService().then((_) {
          debugPrint('[MainShell] AudioService initialized');
        }).catchError((e) {
          debugPrint('[MainShell] AudioService init failed: $e');
        });
        context.read<DownloadsController>().init();
        context.read<LibraryController>().loadLibrary();
        ApiService().checkHealth().then((ok) {
          debugPrint('[MainShell] Backend warmup: $ok');
        });
      });
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        DownloadNotificationService().requestPermission();
      });
      Future.delayed(const Duration(milliseconds: 5000), () {
        if (!mounted) return;
        UpdateDialog.checkAndShow(context);
      });
    });
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    _notifActionSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final engine = context.read<MediaEngine>();
    switch (state) {
      case AppLifecycleState.paused:
        if (!engine.isInPiP) {
          engine.onScreenOff();
        } else {
          debugPrint('[MainShell] Ignoring onScreenOff due to PiP mode');
        }
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.resumed:
        engine.onScreenOn();
        final sincePipExit = engine.pipExitedAt == null
            ? null
            : DateTime.now().difference(engine.pipExitedAt!);
        if (sincePipExit == null || sincePipExit > const Duration(seconds: 5)) {
          context.read<DownloadsController>().init();
          context.read<LibraryController>().loadLibrary();
        }
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                AnalyzerView(),
                DownloadsView(onNavigateToAnalyze: () => _navigateToTab(0)),
                const ExploreView(),
                const LibraryView(),
                const SettingsView(),
              ],
            ),
          ),
          const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.link),
            selectedIcon: Icon(Icons.link, color: colorScheme.primary),
            label: loc.navAnalyze,
          ),
          NavigationDestination(
            icon: const Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download, color: colorScheme.primary),
            label: loc.navDownloads,
          ),
          NavigationDestination(
            icon: const Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore, color: colorScheme.primary),
            label: loc.navExplore,
          ),
          NavigationDestination(
            icon: const Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music, color: colorScheme.primary),
            label: loc.navLibrary,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: colorScheme.primary),
            label: loc.navSettings,
          ),
        ],
      ),
    );
  }
}
