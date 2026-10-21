import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/core/localization/app_localizations.dart';
import 'package:vibegrab/features/whats_new/data/whats_new_catalog.dart';
import 'package:vibegrab/features/whats_new/models/whats_new_entry.dart';
import 'package:vibegrab/features/whats_new/widgets/whats_new_dialog.dart';

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

const _strings = <String, String>{
  'whatsNewTitle': 'Novedades',
  'whatsNewTitleManual': 'Novedades',
  'whatsNewSinceLast': 'Todo lo que ha cambiado desde tu última versión',
  'whatsNewSubtitle': 'Esto es lo nuevo en esta versión',
  'whatsNewVersion': 'Versión {version}',
  'whatsNewClose': 'Cerrar',
  'whatsNewGotIt': 'Entendido',
  'whatsNewCatFeatures': 'Novedades',
  'whatsNewCatImprovements': 'Mejoras',
  'whatsNewCatFixes': 'Correcciones',
  'whatsNewCatStability': 'Estabilidad',
};

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      _StaticAppLocalizationsDelegate(_strings),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, appChild) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(2.0),
      ),
      child: appChild!,
    ),
    home: child,
  );
}

void main() {
  testWidgets(
    'the announcement scrolls instead of overflowing on a short screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = WhatsNewVersionGroup(
        version: '1.1.40',
        build: 45,
        entries: WhatsNewCatalog.entries
            .where((e) => e.version == '1.1.40')
            .toList(),
      );

      await tester.pumpWidget(_harness(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => WhatsNewDialog.show(
                  context,
                  groups: [group],
                  isUpdate: true,
                ),
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();

      // No RenderFlex overflow: the whole content (header included) scrolls.
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollbar), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      // The last card can be reached by scrolling, and still no overflow.
      final lastTitle = group.entries.last.title.es;
      await tester.scrollUntilVisible(
        find.text(lastTitle),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(lastTitle), findsOneWidget);
      expect(find.text('Entendido'), findsOneWidget);
    },
  );
}
