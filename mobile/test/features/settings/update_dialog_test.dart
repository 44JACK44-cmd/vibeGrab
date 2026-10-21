import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/core/localization/app_localizations.dart';
import 'package:vibegrab/features/settings/widgets/update_dialog.dart';
import 'package:vibegrab/services/update_service.dart';

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
  'updateTitle': 'Nueva versión disponible',
  'updateBody': 'Hay una nueva versión de VibeGrab.',
  'updateNow': 'Actualizar ahora',
  'updateLater': 'Más tarde',
  'updateFailed': 'No se pudo descargar. Intenta de nuevo.',
  'updateLatest': 'Estás actualizado.',
  'updateChecking': 'Buscando actualizaciones.',
  'updateCheckFailed': 'No se pudo comprobar actualizaciones.',
  'updateDownloading': 'Descargando la actualización…',
  'updateInstalling': 'Abriendo el instalador…',
  'updateWorking': 'Actualizando…',
  'updatePermissionRequired':
      'Permite que VibeGrab instale actualizaciones y vuelve a intentarlo.',
  'whatsNewOpenFull': 'Ver todo',
};

/// The notes of 1.1.42: a long release. The installed app (1.1.41) does not
/// know this version, so this is the text it has to render.
const _longNotes = '''
<!-- es -->
## ✨ Novedades
- 🎨 **Tres estilos de reproductor** — Elige en Ajustes entre el estilo clásico, el inmersivo con la carátula de fondo y el compacto. El estilo se aplica igual en la biblioteca, en Explorar y en el mini reproductor.
- 🎚️ **Ecualizador y letras en la música** — Al abrir una canción se abre su reproductor completo, con ecualizador, cola y control de reproducción. Las letras se buscan con el título real de la canción y puedes reintentar la búsqueda.
- 🌐 **Filtro de publicidad en el navegador** — El navegador integrado puede detener los anuncios y rastreadores de terceros más conocidos, con un contador discreto, un interruptor para desactivarlo y la opción de permitir un sitio concreto. Los recursos que ya venían en la primera respuesta de la página no se pueden filtrar.

## ⚡ Mejoras
- 🔔 **Las notificaciones de descarga se cierran solas** — El aviso de descarga terminada o fallida desaparece solo tras unos segundos y nunca tapa el trabajo que sigue en marcha. Con varias descargas a la vez hay un aviso por descarga, con su porcentaje y su velocidad real.
- ⚡ **Analizar un enlace va más rápido** — Repetir el análisis del mismo enlace ya no vuelve a lanzar la búsqueda, y el resultado se reutiliza un rato antes de volver a preguntarse al servidor. Si una actualización falla, no pierdes lo que ya tenías.
- 🚀 **Explorar carga antes** — Para ti y Tendencias buscan en varias fuentes a la vez en lugar de una detrás de otra, así que los resultados aparecen antes.

## 🛠️ Correcciones
- 🧹 **Cada descarga aparece una sola vez** — Lo que descargas ya no se repite en Local: la biblioteca unifica el archivo del teléfono y el de la carpeta de descargas, y al borrar una entrada solo se borra esa.
- 🎬 **Los Shorts dicen qué les pasa** — Si un Shorts no puede reproducir el vídeo, la app lo explica y te ofrece reintentar pidiendo enlaces nuevos, en lugar de dejar una carátula quieta sin decir nada.

## 🛡️ Estabilidad
- 📥 **Las descargas que se cortan se reanudan** — Si la conexión se cae a mitad de una descarga, VibeGrab guarda lo descargado y lo retoma con una sola pasada más, en lugar de empezar de cero. El archivo solo aparece en tu carpeta cuando está completo y es válido.
''';

Widget _harness(Widget child, {double textScale = 1.0}) {
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
        textScaler: TextScaler.linear(textScale),
      ),
      child: appChild!,
    ),
    home: child,
  );
}

UpdateAvailableDialog _dialog({String version = '1.1.99', int build = 99}) {
  return UpdateAvailableDialog(
    info: UpdateInfo(
      versionName: version,
      buildNumber: build,
      notes: _longNotes,
      apkUrl: 'https://example.com/VibeGrab.apk',
    ),
  );
}

void main() {
  testWidgets(
    'the long release notes scroll and never cover the buttons',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(_dialog()));
      await tester.pumpAndSettle();

      // No RenderFlex overflow: the notes scroll inside the dialog.
      expect(tester.takeException(), isNull);

      // The button is on screen and reachable.
      final now = find.text('Actualizar ahora');
      expect(now, findsOneWidget);
      expect(tester.getRect(now).bottom, lessThanOrEqualTo(640));
      expect(tester.getRect(now).top, greaterThanOrEqualTo(0));

      // The last note is inside the scrollable content and reachable.
      const lastTitle = 'Las descargas que se cortan se reanudan';
      expect(find.text(lastTitle), findsOneWidget);
      await tester.dragUntilVisible(
        find.text(lastTitle),
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(lastTitle), findsOneWidget);
    },
  );

  testWidgets(
    'the notes do not overflow with a large font size either',
    (tester) async {
      tester.view.physicalSize = const Size(360, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(_dialog(), textScale: 2.0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Actualizar ahora'), findsOneWidget);
    },
  );

  testWidgets(
    'a known version shows the catalogue highlights without overflowing',
    (tester) async {
      tester.view.physicalSize = const Size(360, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(_dialog(version: '1.1.42', build: 50)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Actualizar ahora'), findsOneWidget);
      expect(find.text('Ver todo'), findsOneWidget);
    },
  );

  testWidgets(
    'a failed download is reported in a panel that is always visible',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // The download writes into the app support directory: the test needs
      // a real folder for it.
      final dir = Directory.systemTemp.createTempSync('vibegrab_update_test');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );

      await tester.pumpWidget(_harness(const UpdateAvailableDialog(
        info: UpdateInfo(
          versionName: '1.1.99',
          buildNumber: 99,
          notes: _longNotes,
          // Nothing lives here: the download must fail and the dialog has
          // to say so where the user can see it.
          apkUrl: 'https://localhost:1/VibeGrab.apk',
        ),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Actualizar ahora'));
      await tester.pump();

      // The failure is reported in the fixed panel, not hidden below the
      // notes, and the button can be pressed again.
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
      final error = find.text('No se pudo descargar. Intenta de nuevo.');
      expect(error, findsOneWidget);
      // The message is on screen: the user does not have to scroll to know
      // that the update failed.
      expect(tester.getRect(error).bottom, lessThanOrEqualTo(640));
      expect(tester.getRect(error).top, greaterThanOrEqualTo(0));
      final button = find.text('Actualizar ahora');
      expect(button, findsOneWidget);
      expect(
        tester.getRect(button).bottom,
        lessThanOrEqualTo(640),
      );
    },
  );
}
