import '../models/whats_new_entry.dart';

/// Central registry of every user-facing change, grouped by app version.
///
/// How to add a release:
///   1. Copy the newest `WhatsNewEntry` blocks and bump `version`/`build`
///      to match `pubspec.yaml`.
///   2. Write titles/descriptions from the user's point of view.
///   3. Never list commits, file names or internal class names here.
///
/// The registry is intentionally kept in source (not in the ARB files) because
/// it is *content*, not UI chrome: the UI labels live in the localized strings
/// and this data is picked by language through [LocalizedText].
class WhatsNewCatalog {
  WhatsNewCatalog._();

  /// Display order of the sections.
  static const List<WhatsNewCategory> categoryOrder = [
    WhatsNewCategory.features,
    WhatsNewCategory.improvements,
    WhatsNewCategory.fixes,
    WhatsNewCategory.stability,
  ];

  static const List<WhatsNewEntry> entries = [
    // ----------------------------------------------------------------- 1.1.37
    WhatsNewEntry(
      id: 'wn-1137-update-explained',
      version: '1.1.37',
      build: 42,
      category: WhatsNewCategory.improvements,
      emoji: '🎁',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Las actualizaciones llegan explicadas',
        en: 'Updates arrive explained',
      ),
      description: LocalizedText(
        es: 'A partir de esta versión, cuando salga una nueva, el aviso te cuenta qué cambia con el mismo formato de novedades en lugar de una lista técnica de cambios.',
        en: "From this version on, when a new one comes out, the prompt tells you what changed in the same what's-new format instead of a technical change list.",
      ),
    ),
    // ----------------------------------------------------------------- 1.1.36
    WhatsNewEntry(
      id: 'wn-1136-queue-progress',
      version: '1.1.36',
      build: 41,
      category: WhatsNewCategory.features,
      emoji: '📥',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Sigue tus descargas sin salir de donde estás',
        en: 'Track your downloads without leaving what you are doing',
      ),
      description: LocalizedText(
        es: 'Un panel compacto con el progreso de las descargas en curso, visible desde cualquier pantalla, con acceso directo a la lista de descargas.',
        en: 'A compact panel with the progress of the ongoing downloads, visible from any screen, with a shortcut to the download list.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1136-faster',
      version: '1.1.36',
      build: 41,
      category: WhatsNewCategory.improvements,
      emoji: '⚡',
      order: 0,
      title: LocalizedText(
        es: 'Explorer, Shorts y Descargas abren antes',
        en: 'Explorer, Shorts and Downloads open sooner',
      ),
      description: LocalizedText(
        es: 'La portada ya no espera a tener la lista entera para empezar a reproducir, el feed de Shorts aparece casi al instante y el análisis de un enlace se reutiliza en lugar de repetirse.',
        en: 'The home screen no longer waits for the whole list before it can play, the Shorts feed appears almost instantly and analysing a link is reused instead of repeated.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1136-background-audio',
      version: '1.1.36',
      build: 41,
      category: WhatsNewCategory.improvements,
      emoji: '🔊',
      order: 1,
      title: LocalizedText(
        es: 'El sonido no se corta al apagar la pantalla ni al minimizar',
        en: 'The sound no longer cuts out when the screen turns off or you minimise',
      ),
      description: LocalizedText(
        es: 'El relevo al audio de fondo se prepara antes de parar el vídeo, así la música sigue sin saltos. Y al volver a la app el vídeo se recupera mientras el audio sigue sonando.',
        en: 'The handoff to background audio is prepared before the video stops, so the music continues without gaps. Coming back to the app, the video is restored while the audio keeps playing.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1136-image-download',
      version: '1.1.36',
      build: 41,
      category: WhatsNewCategory.improvements,
      emoji: '🖼️',
      order: 2,
      title: LocalizedText(
        es: 'Guarda la miniatura o la imagen del vídeo',
        en: 'Save the cover or the image of a video',
      ),
      description: LocalizedText(
        es: 'La acción de imagen aparece solo cuando el vídeo la tiene, se guarda con su formato real (PNG o WebP) y acaba en tu galería.',
        en: 'The image action shows up only when the video has one; it is saved in its real format (PNG or WebP) and ends up in your gallery.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1136-play-button',
      version: '1.1.36',
      build: 41,
      category: WhatsNewCategory.fixes,
      emoji: '▶️',
      order: 0,
      title: LocalizedText(
        es: 'Un toque en reproducir ya basta',
        en: 'One tap on play is enough now',
      ),
      description: LocalizedText(
        es: 'El botón de reproducción ya no se queda mudo si lo pulsas mientras el vídeo todavía se está cargando.',
        en: 'The play button no longer goes mute if you tap it while the video is still loading.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1136-shorts-follow',
      version: '1.1.36',
      build: 41,
      category: WhatsNewCategory.fixes,
      emoji: '🎬',
      order: 1,
      title: LocalizedText(
        es: 'Shorts: la pantalla sigue al reproductor',
        en: 'Shorts: the feed follows the player',
      ),
      description: LocalizedText(
        es: 'Cuando un short termina solo o usas los controles de la notificación, el feed se mueve con él en lugar de quedarse en el anterior.',
        en: 'When a short ends by itself or you use the notification controls, the feed moves along with it instead of staying on the previous one.',
      ),
    ),
    // ----------------------------------------------------------------- 1.1.35
    WhatsNewEntry(
      id: 'wn-1135-notes',
      version: '1.1.35',
      build: 40,
      category: WhatsNewCategory.features,
      emoji: '🎉',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Descubre qué cambió en cada versión',
        en: 'See what changed in every version',
      ),
      description: LocalizedText(
        es: 'Al actualizar verás una pantalla de novedades clara y ordenada, con las funciones, mejoras y correcciones de cada versión.',
        en: "After updating you will see a clear, tidy what's-new screen with the features, improvements and fixes of each version.",
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1135-update-preview',
      version: '1.1.35',
      build: 40,
      category: WhatsNewCategory.improvements,
      emoji: '🚀',
      order: 0,
      title: LocalizedText(
        es: 'Sabes qué cambia antes de actualizar',
        en: 'Know what changes before updating',
      ),
      description: LocalizedText(
        es: 'El aviso de nueva versión resume los cambios principales y puedes abrir el detalle completo.',
        en: 'The new-version prompt summarises the main changes and lets you open the full detail.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.34
    WhatsNewEntry(
      id: 'wn-1134-statusbar',
      version: '1.1.34',
      build: 39,
      category: WhatsNewCategory.fixes,
      emoji: '📱',
      order: 0,
      title: LocalizedText(
        es: 'Sin solapamientos arriba',
        en: 'No more overlap at the top',
      ),
      description: LocalizedText(
        es: 'La barra de estado y el área de notificaciones ya no tapan el contenido de la parte superior.',
        en: 'The status bar and the notification area no longer cover the content at the top.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.33
    WhatsNewEntry(
      id: 'wn-1133-browser',
      version: '1.1.33',
      build: 38,
      category: WhatsNewCategory.features,
      emoji: '🌐',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Navegador con su propia página de inicio',
        en: 'Browser with its own start page',
      ),
      description: LocalizedText(
        es: 'Abre cualquier página web dentro de VibeGrab, con accesos rápidos a los sitios más usados.',
        en: 'Open any website inside VibeGrab, with quick shortcuts to popular sites.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1133-player-time',
      version: '1.1.33',
      build: 38,
      category: WhatsNewCategory.fixes,
      emoji: '⏱️',
      order: 0,
      title: LocalizedText(
        es: 'Tiempo y cola más fiables',
        en: 'More reliable time and queue',
      ),
      description: LocalizedText(
        es: 'Se corrigió el tiempo de reproducción y el manejo de la cola al avanzar o cambiar de contenido.',
        en: 'Fixed the playback time and the queue when seeking or switching content.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.32
    WhatsNewEntry(
      id: 'wn-1132-one-tap',
      version: '1.1.32',
      build: 37,
      category: WhatsNewCategory.features,
      emoji: '⬇️',
      order: 0,
      title: LocalizedText(
        es: 'Descarga en un toque desde el navegador',
        en: 'One-tap download from the browser',
      ),
      description: LocalizedText(
        es: 'Descarga lo que estás viendo en el navegador integrado sin salir de la app.',
        en: 'Download what you are watching in the built-in browser without leaving the app.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.31
    WhatsNewEntry(
      id: 'wn-1131-restart',
      version: '1.1.31',
      build: 36,
      category: WhatsNewCategory.fixes,
      emoji: '▶️',
      order: 0,
      title: LocalizedText(
        es: 'El reproductor ya no se reinicia',
        en: 'The player no longer restarts',
      ),
      description: LocalizedText(
        es: 'Correcciones que evitaban que el contenido volviera a empezar al iniciar la reproducción.',
        en: 'Fixes that stopped content from starting over when playback began.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1131-flow',
      version: '1.1.31',
      build: 36,
      category: WhatsNewCategory.improvements,
      emoji: '⚡',
      order: 0,
      title: LocalizedText(
        es: 'Descarga en un toque más fluida',
        en: 'Smoother one-tap download',
      ),
      description: LocalizedText(
        es: 'Mejoras en el flujo de descarga con un solo toque.',
        en: 'Improvements to the single-tap download flow.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.30
    WhatsNewEntry(
      id: 'wn-1130-home',
      version: '1.1.30',
      build: 35,
      category: WhatsNewCategory.features,
      emoji: '🎬',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Una experiencia más familiar',
        en: 'A more familiar experience',
      ),
      description: LocalizedText(
        es: 'Inicio primero, sección de videos cortos, elección de calidad y velocidad, y navegación con gestos.',
        en: 'Home first, a section for short videos, quality and speed selection, and gesture navigation.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.29
    WhatsNewEntry(
      id: 'wn-1129-region',
      version: '1.1.29',
      build: 34,
      category: WhatsNewCategory.features,
      emoji: '🌍',
      order: 0,
      title: LocalizedText(
        es: 'Contenido de tu región e idioma',
        en: 'Content for your region and language',
      ),
      description: LocalizedText(
        es: 'Las recomendaciones se adaptan a tu país e idioma.',
        en: 'Recommendations adapt to your country and language.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1129-for-you',
      version: '1.1.29',
      build: 34,
      category: WhatsNewCategory.features,
      emoji: '✨',
      order: 1,
      title: LocalizedText(
        es: '«Para ti» más personalizado',
        en: 'A more personal «For you»',
      ),
      description: LocalizedText(
        es: 'Recomendaciones basadas en tus intereses y en tu historial.',
        en: 'Recommendations based on your interests and your history.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.28
    WhatsNewEntry(
      id: 'wn-1128-playback',
      version: '1.1.28',
      build: 33,
      category: WhatsNewCategory.fixes,
      emoji: '🎵',
      order: 0,
      title: LocalizedText(
        es: 'Reproducción más estable en segundo plano',
        en: 'More stable background playback',
      ),
      description: LocalizedText(
        es: 'Correcciones en duración, avance, reproducción en segundo plano y controles de la notificación.',
        en: 'Fixes for duration, seeking, background playback and the notification controls.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.27
    WhatsNewEntry(
      id: 'wn-1127-feed',
      version: '1.1.27',
      build: 32,
      category: WhatsNewCategory.improvements,
      emoji: '🚀',
      order: 0,
      title: LocalizedText(
        es: 'Inicio más rápido',
        en: 'Faster home',
      ),
      description: LocalizedText(
        es: 'El contenido aparece antes al abrir la app.',
        en: 'Content appears sooner when you open the app.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1127-external-links',
      version: '1.1.27',
      build: 32,
      category: WhatsNewCategory.features,
      emoji: '🔗',
      order: 0,
      title: LocalizedText(
        es: 'Enlaces externos en el reproductor',
        en: 'External links in the player',
      ),
      description: LocalizedText(
        es: 'Abre enlaces compartidos desde otras apps dentro de VibeGrab.',
        en: 'Open links shared from other apps right inside VibeGrab.',
      ),
    ),

    // ----------------------------------------------------------------- 1.1.26
    WhatsNewEntry(
      id: 'wn-1126-like',
      version: '1.1.26',
      build: 31,
      category: WhatsNewCategory.fixes,
      emoji: '❤️',
      order: 0,
      title: LocalizedText(
        es: 'Like sin parpadeo',
        en: 'No more flicker when liking',
      ),
      description: LocalizedText(
        es: 'El botón de «me gusta» ya no parpadea al pulsarlo.',
        en: 'The like button no longer flickers when you tap it.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1126-duplicates',
      version: '1.1.26',
      build: 31,
      category: WhatsNewCategory.fixes,
      emoji: '🧹',
      order: 1,
      title: LocalizedText(
        es: 'Sin contenido duplicado',
        en: 'No duplicate content',
      ),
      description: LocalizedText(
        es: 'Se eliminaron los videos repetidos en el feed de Explorer.',
        en: 'Repeated videos were removed from the Explorer feed.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1126-audio-fallback',
      version: '1.1.26',
      build: 31,
      category: WhatsNewCategory.stability,
      emoji: '🔒',
      order: 0,
      title: LocalizedText(
        es: 'Más compatible con distintas fuentes',
        en: 'More compatible with different sources',
      ),
      description: LocalizedText(
        es: 'Si una fuente de audio no responde, la app prueba otra automáticamente.',
        en: 'If one audio source does not respond, the app automatically tries another.',
      ),
    ),
  ];

  /// Compares two `version`/`build` pairs. Returns a negative number when the
  /// first is older, zero when equal and a positive number when newer.
  static int compare(String versionA, int buildA, String versionB, int buildB) {
    final a = _parts(versionA);
    final b = _parts(versionB);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return buildA.compareTo(buildB);
  }

  static List<int> _parts(String version) =>
      version.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();

  /// Entries newer than `lastVersion`/`lastBuild` (exclusive) and not newer
  /// than `currentVersion`/`currentBuild` (inclusive).
  ///
  /// This is what a user sees after skipping several releases at once.
  static List<WhatsNewEntry> changesSince({
    required String lastVersion,
    required int lastBuild,
    required String currentVersion,
    required int currentBuild,
  }) {
    final result = entries.where((e) {
      final newerThanLast = compare(e.version, e.build, lastVersion, lastBuild) > 0;
      final notNewerThanCurrent =
          compare(e.version, e.build, currentVersion, currentBuild) <= 0;
      return newerThanLast && notNewerThanCurrent;
    }).toList();
    return _sorted(result);
  }

  /// Every entry registered for exactly `version`/`build`.
  static List<WhatsNewEntry> forVersion(String version, int build) => _sorted(
        entries
            .where((e) => e.version == version && e.build == build)
            .toList(),
      );

  /// The newest registered version group(s), newest first.
  ///
  /// Used by the manual "What's new" entry in Settings.
  static List<WhatsNewVersionGroup> latestGroups({int maxVersions = 1}) {
    final groups = groupByVersion(entries);
    return groups.take(maxVersions).toList();
  }

  /// Groups a flat list of entries by version, newest first.
  static List<WhatsNewVersionGroup> groupByVersion(List<WhatsNewEntry> list) {
    final byVersion = <String, List<WhatsNewEntry>>{};
    for (final entry in list) {
      final key = '${entry.version}+${entry.build}';
      byVersion.putIfAbsent(key, () => <WhatsNewEntry>[]).add(entry);
    }
    final groups = byVersion.entries.map((e) {
      final first = e.value.first;
      return WhatsNewVersionGroup(
        version: first.version,
        build: first.build,
        entries: _sorted(e.value),
      );
    }).toList();
    groups.sort((a, b) => compare(b.version, b.build, a.version, a.build));
    return groups;
  }

  /// Splits the entries into category sections (empty ones are dropped).
  static List<WhatsNewSection> sectionsOf(List<WhatsNewEntry> list) {
    final sorted = _sorted(list);
    final sections = <WhatsNewSection>[];
    for (final category in categoryOrder) {
      final items = sorted.where((e) => e.category == category).toList();
      if (items.isNotEmpty) {
        sections.add(WhatsNewSection(category: category, entries: items));
      }
    }
    return sections;
  }

  /// A short selection for previews: featured entries first, then the rest.
  static List<WhatsNewEntry> highlights(List<WhatsNewEntry> list, {int max = 4}) {
    final sorted = _sorted(list);
    final featured = sorted.where((e) => e.featured);
    final rest = sorted.where((e) => !e.featured);
    return [...featured, ...rest].take(max).toList();
  }

  /// Newest version first, then category order, then `order`.
  static List<WhatsNewEntry> _sorted(List<WhatsNewEntry> list) {
    final copy = List<WhatsNewEntry>.of(list);
    copy.sort((a, b) {
      final byVersion = compare(b.version, b.build, a.version, a.build);
      if (byVersion != 0) return byVersion;
      final byCategory = a.category.index.compareTo(b.category.index);
      if (byCategory != 0) return byCategory;
      final byOrder = a.order.compareTo(b.order);
      if (byOrder != 0) return byOrder;
      return a.id.compareTo(b.id);
    });
    return copy;
  }
}
