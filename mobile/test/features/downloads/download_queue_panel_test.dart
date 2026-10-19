import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:vibegrab/core/localization/app_localizations.dart';
import 'package:vibegrab/data/models/download_task.dart';
import 'package:vibegrab/features/downloads/controllers/downloads_controller.dart';
import 'package:vibegrab/features/downloads/widgets/download_queue_panel.dart';

/// Void callback used by the const panels below.
void noop() {}

/// Serves a fixed task list through the real controller API without ever
/// touching the download pipeline: the panel must be a pure view over
/// [DownloadsController.tasks] and [ChangeNotifier] notifications.
class _FakeDownloadsController extends DownloadsController {
  List<DownloadTask> _testTasks = const [];

  void emit(List<DownloadTask> tasks) {
    _testTasks = tasks;
    notifyListeners();
  }

  @override
  List<DownloadTask> get tasks => List.unmodifiable(_testTasks);
}

DownloadTask _task({
  String id = 'dl_1',
  String title = 'My video',
  DownloadStatus status = DownloadStatus.downloading,
  double progress = 0.0,
}) {
  return DownloadTask(
    id: id,
    url: 'https://example.com/$id',
    title: title,
    formatId: '18',
    thumbnail: 'https://i.ytimg.com/vi/abc/hqdefault.jpg',
    status: status,
    progress: progress,
    createdAt: DateTime(2026, 1, 1).toIso8601String(),
  );
}

/// Spanish strings read straight from the ARB file.
///
/// Widget tests cannot rely on [AppLocalizations.delegate]: it loads the
/// asset through the engine, and the engine only answers that read once per
/// test process, so the second test in a file would wait forever. The
/// delegate below provides the same strings synchronously instead.
Map<String, String> _esStrings = {};

class _StaticAppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _StaticAppLocalizationsDelegate(this.strings);

  final Map<String, String> strings;

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(
          AppLocalizations.fromMap(locale, strings));

  @override
  bool isSupported(Locale locale) => true;

  @override
  bool shouldReload(_StaticAppLocalizationsDelegate old) => false;
}

Widget _harness(_FakeDownloadsController controller, Widget child) {
  return ChangeNotifierProvider<DownloadsController>.value(
    value: controller,
    child: MaterialApp(
      locale: const Locale('es'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        _StaticAppLocalizationsDelegate(_esStrings),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    ),
  );
}

/// Mounts the harness. The extra pump lets the widget tree build once the
/// delegates have resolved.
Future<void> _show(
    WidgetTester tester, _FakeDownloadsController controller, Widget child) async {
  await tester.pumpWidget(_harness(controller, child));
  await tester.pump();
}

void main() {
  setUpAll(() {
    final raw = json.decode(
            File('lib/core/localization/app_es.arb').readAsStringSync())
        as Map<String, dynamic>;
    _esStrings = {
      for (final entry in raw.entries)
        if (!entry.key.startsWith('@')) entry.key: entry.value.toString(),
    };
  });

  testWidgets('stays hidden while no download is live', (tester) async {
    final controller = _FakeDownloadsController();
    await _show(tester, controller, const DownloadQueuePanel(onOpenDownloads: noop));

    expect(find.byType(DownloadQueuePanel), findsOneWidget);
    expect(find.text('Ver descargas'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('reports a download queued after the panel was built',
      (tester) async {
    final controller = _FakeDownloadsController();
    await _show(tester, controller, const DownloadQueuePanel(onOpenDownloads: noop));

    controller.emit([_task(progress: 0.42)]);
    await tester.pump();

    expect(find.text('My video'), findsOneWidget);
    expect(find.text('Ver descargas'), findsOneWidget);
    expect(find.text('Descargas'), findsOneWidget);

    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(0.42, 0.0001));
  });

  testWidgets('stays indeterminate before any byte progress exists',
      (tester) async {
    final controller = _FakeDownloadsController();
    await _show(tester, controller, const DownloadQueuePanel(onOpenDownloads: noop));

    controller.emit([_task(id: 'dl_p', status: DownloadStatus.resolving)]);
    await tester.pump();

    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, isNull);
  });

  testWidgets('"Ver descargas" opens the downloads screen', (tester) async {
    var opened = 0;
    final controller = _FakeDownloadsController();
    await _show(
        tester, controller, DownloadQueuePanel(onOpenDownloads: () => opened++));

    controller.emit([_task()]);
    await tester.pump();

    await tester.tap(find.text('Ver descargas'));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets(
      'closing the panel hides it without cancelling the download and a new '
      'download brings it back', (tester) async {
    final controller = _FakeDownloadsController();
    await _show(tester, controller, const DownloadQueuePanel(onOpenDownloads: noop));

    controller.emit([_task()]);
    await tester.pump();
    expect(find.text('My video'), findsOneWidget);

    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pump();

    expect(find.text('My video'), findsNothing);
    expect(find.text('Ver descargas'), findsNothing);
    // The queue itself is untouched: the panel only owns its own visibility.
    expect(controller.tasks, hasLength(1));
    expect(controller.tasks.single.status, DownloadStatus.downloading);

    controller.emit([
      _task(),
      _task(id: 'dl_2', title: 'Second video'),
    ]);
    await tester.pump();

    expect(find.text('Second video'), findsOneWidget);
    expect(find.text('My video'), findsOneWidget);
  });

  testWidgets('is not rendered while the downloads screen is open',
      (tester) async {
    final controller = _FakeDownloadsController();
    await _show(
        tester,
        controller,
        const DownloadQueuePanel(
          onOpenDownloads: noop,
          visible: false,
        ));

    controller.emit([_task()]);
    await tester.pump();

    expect(find.text('My video'), findsNothing);
    expect(find.text('Ver descargas'), findsNothing);
  });
}
