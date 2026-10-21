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
    // ----------------------------------------------------------------- 1.1.42
    WhatsNewEntry(
      id: 'wn-1142-player-styles',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.features,
      emoji: '🎨',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Tres estilos de reproductor',
        en: 'Three player styles',
      ),
      description: LocalizedText(
        es: 'Elige en Ajustes entre el estilo clásico, el inmersivo con la carátula de fondo y el compacto. El estilo se aplica igual en la biblioteca, en Explorar y en el mini reproductor.',
        en: 'Choose between the classic style, the immersive one with the artwork in the background and the compact one in Settings. The style is applied the same way in your library, in Explore and in the mini player.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-audio-player',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.fixes,
      emoji: '🎚️',
      order: 1,
      featured: true,
      title: LocalizedText(
        es: 'El ecualizador y las letras ya están en la música',
        en: 'Equalizer and lyrics are now in the music player',
      ),
      description: LocalizedText(
        es: 'Al abrir una canción se abre su reproductor completo, con ecualizador, cola y control de reproducción. Las letras se buscan con el título real de la canción y puedes reintentar la búsqueda.',
        en: 'Opening a song now opens its full player, with the equalizer, the queue and the playback controls. Lyrics are searched with the real song title and you can retry the search.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-library-duplicates',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.fixes,
      emoji: '🧹',
      order: 2,
      title: LocalizedText(
        es: 'Cada descarga aparece una sola vez',
        en: 'Each download shows up only once',
      ),
      description: LocalizedText(
        es: 'Lo que descargas ya no se repite en Local: la biblioteca unifica el archivo del teléfono y el de la carpeta de descargas, y al borrar una entrada solo se borra esa.',
        en: 'What you download no longer repeats in your library: the library merges the phone file with the one in the downloads folder, and deleting one entry only removes that one.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-notifications',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.improvements,
      emoji: '🔔',
      order: 3,
      title: LocalizedText(
        es: 'Las notificaciones de descarga se cierran solas',
        en: 'Download notifications close on their own',
      ),
      description: LocalizedText(
        es: 'El aviso de descarga terminada o fallida desaparece solo tras unos segundos y nunca tapa el trabajo que sigue en marcha. Con varias descargas a la vez hay un aviso por descarga, con su porcentaje y su velocidad real.',
        en: 'The finished or failed download notice disappears on its own after a few seconds and never covers work that is still running. With several downloads at once there is one notice per download, with its percentage and its real speed.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-analysis-speed',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.improvements,
      emoji: '⚡',
      order: 4,
      title: LocalizedText(
        es: 'Analizar un enlace va más rápido',
        en: 'Analysing a link is faster',
      ),
      description: LocalizedText(
        es: 'Repetir el análisis del mismo enlace ya no vuelve a lanzar la búsqueda, y el resultado se reutiliza un rato antes de volver a preguntarse al servidor. Si una actualización falla, no pierdes lo que ya tenías.',
        en: 'Repeating the analysis of the same link no longer starts the search again, and the result is reused for a while before asking the server again. If an update fails, you do not lose what you already had.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-resume',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.stability,
      emoji: '📥',
      order: 5,
      title: LocalizedText(
        es: 'Las descargas que se cortan se reanudan',
        en: 'Interrupted downloads pick up where they stopped',
      ),
      description: LocalizedText(
        es: 'Si la conexión se cae a mitad de una descarga, VibeGrab guarda lo descargado y lo retoma con una sola pasada más, en lugar de empezar de cero. El archivo solo aparece en tu carpeta cuando está completo y es válido.',
        en: 'If the connection drops halfway through a download, VibeGrab keeps what was downloaded and resumes it with one extra attempt instead of starting over. The file only appears in your folder when it is complete and valid.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-shorts',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.fixes,
      emoji: '🎬',
      order: 6,
      title: LocalizedText(
        es: 'Los Shorts dicen qué les pasa',
        en: 'Shorts now tell you what is wrong',
      ),
      description: LocalizedText(
        es: 'Si un Shorts no puede reproducir el vídeo, la app lo explica y te ofrece reintentar pidiendo enlaces nuevos, en lugar de dejar una carátula quieta sin decir nada.',
        en: 'If a Short cannot play the video, the app explains it and offers to retry with fresh links instead of leaving a still thumbnail with no explanation.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-browser-blocker',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.features,
      emoji: '🌐',
      order: 7,
      title: LocalizedText(
        es: 'Filtro de publicidad en el navegador',
        en: 'Ad filter in the browser',
      ),
      description: LocalizedText(
        es: 'El navegador integrado puede detener los anuncios y rastreadores de terceros más conocidos, con un contador discreto, un interruptor para desactivarlo y la opción de permitir un sitio concreto. Los recursos que ya venían en la primera respuesta de la página no se pueden filtrar.',
        en: 'The built-in browser can stop the best known third-party ads and trackers, with a discreet counter, a switch to turn it off and the option to allow a specific site. Resources already included in the first page response cannot be filtered.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1142-explorer-parallel',
      version: '1.1.42',
      build: 50,
      category: WhatsNewCategory.improvements,
      emoji: '🚀',
      order: 8,
      title: LocalizedText(
        es: 'Explorar carga antes',
        en: 'Explore loads sooner',
      ),
      description: LocalizedText(
        es: 'Para ti y Tendencias buscan en varias fuentes a la vez en lugar de una detrás de otra, así que los resultados aparecen antes sin esperar a que termine cada búsqueda.',
        en: 'For you and Trending search several sources at once instead of one after another, so results appear sooner without waiting for every search to finish.',
      ),
    ),
    // ----------------------------------------------------------------- 1.1.41
    WhatsNewEntry(
      id: 'wn-1141-mp3-real',
      version: '1.1.41',
      build: 48,
      category: WhatsNewCategory.fixes,
      emoji: '🎵',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Las descargas MP3 ya no se quedan sin fuente',
        en: 'MP3 downloads no longer run out of sources',
      ),
      description: LocalizedText(
        es: 'La opción MP3 usa directamente la pista de audio que el teléfono ya tiene firmada, sin pedir el manifiesto por segunda vez. Si el video solo trae una pista combinada, se descarga esa pista y se convierte en un MP3 real en el servidor.',
        en: 'The MP3 option now uses the audio track your phone already has signed, without asking for the manifest a second time. If the video only has a combined track, that track is downloaded and turned into a real MP3 on the server.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1141-no-duplicates',
      version: '1.1.41',
      build: 48,
      category: WhatsNewCategory.fixes,
      emoji: '🧹',
      order: 1,
      featured: true,
      title: LocalizedText(
        es: 'Una descarga, un archivo',
        en: 'One download, one file',
      ),
      description: LocalizedText(
        es: 'Las pistas temporales que se usan para convertir o unir ya no aparecen en tu carpeta de descargas como si fueran un video extra. Además, tocar dos veces el mismo formato ya no encola el trabajo duplicado.',
        en: 'Temporary tracks used for converting or muxing no longer show up in your downloads folder as an extra video. Double-tapping the same format also no longer queues the job twice.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1141-whats-new-scroll',
      version: '1.1.41',
      build: 48,
      category: WhatsNewCategory.fixes,
      emoji: '📜',
      order: 2,
      featured: false,
      title: LocalizedText(
        es: 'El aviso de novedades ya se lee completo',
        en: 'The update announcement is fully readable',
      ),
      description: LocalizedText(
        es: 'La cabecera y las tarjetas del aviso se desplazan juntas cuando el texto no cabe en la pantalla, también con el tamaño de letra grande. Ya no se cortan títulos ni descripciones.',
        en: 'The announcement header and cards scroll together when the text does not fit on screen, including with large font sizes. Titles and descriptions are no longer cut off.',
      ),
    ),
    // ----------------------------------------------------------------- 1.1.40
    WhatsNewEntry(
      id: 'wn-1140-browser',
      version: '1.1.40',
      build: 45,
      category: WhatsNewCategory.features,
      emoji: '🌐',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Navegador integrado para encontrar y descargar',
        en: 'Built-in browser to find and download',
      ),
      description: LocalizedText(
        es: 'Abre páginas dentro de VibeGrab, vuelve atrás, detén o recarga, cambia a vista de escritorio y descarga los archivos que encuentres. El navegador solo carga páginas web seguras y no activa permisos por su cuenta.',
        en: 'Open pages inside VibeGrab, go back, stop or reload, switch to desktop view and download the files you find. The browser only loads web pages and never grants site permissions on its own.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1140-trash',
      version: '1.1.40',
      build: 45,
      category: WhatsNewCategory.features,
      emoji: '🗑️',
      order: 1,
      title: LocalizedText(
        es: 'Papelera con restauración real',
        en: 'Trash with real restore',
      ),
      description: LocalizedText(
        es: 'Al borrar un archivo va a la papelera junto con su carátula y sus datos. Puedes restaurarlo en su carpeta original o borrarlo definitivamente; nada se elimina sin confirmación.',
        en: 'When you delete a file it goes to the trash together with its artwork and details. You can restore it to its original folder or delete it permanently; nothing is removed without confirmation.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1140-whatsapp-statuses',
      version: '1.1.40',
      build: 45,
      category: WhatsNewCategory.features,
      emoji: '💬',
      order: 2,
      title: LocalizedText(
        es: 'Estados de WhatsApp disponibles para guardar',
        en: 'WhatsApp statuses ready to save',
      ),
      description: LocalizedText(
        es: 'VibeGrab muestra los estados que WhatsApp guarda en el teléfono y permite guardarlos en la galería o compartirlos. Solo aparecen archivos reales y accesibles; si Android bloquea la carpeta, la app lo indica y pide el permiso correcto.',
        en: 'VibeGrab shows the statuses WhatsApp stores on the phone and lets you save them to the gallery or share them. Only real, accessible files are listed; if Android blocks the folder, the app says so and requests the correct permission.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1140-diagnostics-dns',
      version: '1.1.40',
      build: 45,
      category: WhatsNewCategory.improvements,
      emoji: '🩺',
      order: 0,
      title: LocalizedText(
        es: 'Diagnóstico claro de red y DNS',
        en: 'Clear network and DNS diagnostics',
      ),
      description: LocalizedText(
        es: 'Las pruebas indican la operación, la etapa, el código HTTP y el tipo de error, sin mostrar enlaces firmados ni datos privados. El panel de DNS muestra el modo real del sistema y aclara que no cambia el DNS de otras aplicaciones ni del navegador interno.',
        en: 'Checks report the operation, stage, HTTP status and error type without showing signed links or private data. The DNS panel shows the system’s real mode and makes clear that it does not change the DNS of other apps or the built-in browser.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1140-download-integrity',
      version: '1.1.40',
      build: 45,
      category: WhatsNewCategory.fixes,
      emoji: '🎵',
      order: 0,
      title: LocalizedText(
        es: 'MP3 y descargas con el formato correcto',
        en: 'MP3 and downloads keep the right format',
      ),
      description: LocalizedText(
        es: 'El MP3 se genera a partir de la pista de audio real aunque la fuente sea vídeo, y se comprueba el contenido antes de darlo por terminado. Las descargas del navegador conservan su extensión y los archivos incompletos se descartan.',
        en: 'MP3 is generated from the real audio track even when the source is video, and the content is checked before marking it complete. Browser downloads keep their extension and incomplete files are discarded.',
      ),
    ),
    // ----------------------------------------------------------------- 1.1.39
    WhatsNewEntry(
      id: 'wn-1139-device-downloads',
      version: '1.1.39',
      build: 44,
      category: WhatsNewCategory.features,
      emoji: '📥',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Las descargas que antes fallaban ya se completan',
        en: 'Downloads that used to fail now complete',
      ),
      description: LocalizedText(
        es: 'El audio y el vídeo se descargan con la conexión del propio teléfono y el servidor solo hace la conversión final. Así funciona el MP3 de verdad, el vídeo con su audio y las pistas de música aunque la fuente no esté disponible desde el servidor.',
        en: "Audio and video are downloaded with the phone's own connection and the server only does the final conversion. That is how the real MP3, the video with its audio and the music tracks work even when the source is not reachable from the server.",
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1139-error-details',
      version: '1.1.39',
      build: 44,
      category: WhatsNewCategory.improvements,
      emoji: '🧭',
      order: 0,
      title: LocalizedText(
        es: 'Si algo falla, ahora sabes por qué',
        en: 'If something fails, now you know why',
      ),
      description: LocalizedText(
        es: 'Los errores distinguen entre fuente no disponible, formato incompatible, problema de red, tiempo agotado, espacio insuficiente o conversión fallida, en lugar de un mensaje genérico de error del servidor. Puedes reintentar cuando tenga sentido.',
        en: 'Errors tell apart an unavailable source, an incompatible format, a network problem, a timeout, not enough space or a failed conversion, instead of a generic server error message. You can retry when it makes sense.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1139-screen-off-audio',
      version: '1.1.39',
      build: 44,
      category: WhatsNewCategory.fixes,
      emoji: '🔊',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'El sonido sigue al apagar la pantalla',
        en: 'Sound keeps going when the screen turns off',
      ),
      description: LocalizedText(
        es: 'Al apagar la pantalla el audio continúa y el tiempo avanza; desde la notificación puedes pausar, reanudar y volver, y al encender la pantalla el vídeo y el sonido siguen sincronizados. Ya no hace falta pulsar Play otra vez.',
        en: 'When the screen turns off the audio continues and the time keeps advancing; from the notification you can pause, resume and go back, and when the screen turns on the video and the sound are still in sync. There is no need to press Play again.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1139-grey-thumbnail',
      version: '1.1.39',
      build: 44,
      category: WhatsNewCategory.fixes,
      emoji: '🖼️',
      order: 1,
      title: LocalizedText(
        es: 'Sin recuadro gris al minimizar el reproductor',
        en: 'No grey box when the player is minimized',
      ),
      description: LocalizedText(
        es: 'La carátula se guarda en el teléfono al empezar a reproducir, así aparece al instante al minimizar o al volver de la ventana pequeña, en lugar de un hueco gris mientras carga.',
        en: 'The artwork is saved on the phone when playback starts, so it appears instantly when minimizing or coming back from the small window, instead of a grey gap while it loads.',
      ),
    ),
    // ----------------------------------------------------------------- 1.1.38
    WhatsNewEntry(
      id: 'wn-1138-real-mp3',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.features,
      emoji: '🎵',
      order: 0,
      featured: true,
      title: LocalizedText(
        es: 'Tus audios ahora son MP3 de verdad',
        en: 'Your audio downloads are real MP3 files now',
      ),
      description: LocalizedText(
        es: 'Al descargar solo el audio, el archivo sale en MP3 reproducible en cualquier reproductor, con el título, el artista y la carátula dentro del propio archivo.',
        en: 'When you download only the audio, the file comes out as a playable MP3 in any player, with the title, the artist and the cover inside the file itself.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1138-tiktok-photos',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.features,
      emoji: '🖼️',
      order: 1,
      title: LocalizedText(
        es: 'Los posts de fotos de TikTok ya se descargan',
        en: 'TikTok photo posts can be downloaded now',
      ),
      description: LocalizedText(
        es: 'Los enlaces de fotos con música ofrecen lo que de verdad tienen: la música para guardarla como MP3 y la imagen del post. Ya no aparece una opción de vídeo que no existe.',
        en: 'Photo links with music offer what they really have: the music to save as an MP3 and the image of the post. A video option that does not exist no longer shows up.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1138-explorer-start',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.improvements,
      emoji: '⚡',
      order: 0,
      title: LocalizedText(
        es: 'La reproducción en Explorer empieza antes',
        en: 'Explorer playback starts sooner',
      ),
      description: LocalizedText(
        es: 'La dirección del vídeo que vas a reproducir se busca mientras se cierra el anterior, así el primer fotograma llega antes y se evita tocar Play dos veces.',
        en: 'The address of the video you are about to play is looked up while the previous one is closing, so the first frame arrives sooner and there is no need to tap Play twice.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1138-analysis',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.improvements,
      emoji: '📊',
      order: 1,
      title: LocalizedText(
        es: 'Análisis de enlaces más completo y más rápido',
        en: 'Link analysis is more complete and faster',
      ),
      description: LocalizedText(
        es: 'El análisis devuelve todas las calidades y pistas de audio disponibles (en algunos vídeos solo aparecía una) y responde antes; repetir el mismo enlace es instantáneo.',
        en: 'The analysis returns every available quality and audio track (on some videos only one used to show up) and answers sooner; repeating the same link is instant.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1138-file-cover',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.improvements,
      emoji: '💿',
      order: 2,
      title: LocalizedText(
        es: 'El reproductor enseña la carátula del archivo',
        en: 'The player shows the cover inside the file',
      ),
      description: LocalizedText(
        es: 'Al reproducir una descarga, el reproductor y la notificación muestran el título, el artista y la carátula que lleva dentro el propio archivo, aunque falten los datos de la descarga.',
        en: 'When you play a download, the player and the notification show the title, the artist and the cover the file itself carries, even if the download details are missing.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1138-settings-blocks',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.improvements,
      emoji: '⚙️',
      order: 3,
      title: LocalizedText(
        es: 'Ajustes, ordenado por bloques',
        en: 'Settings, ordered in blocks',
      ),
      description: LocalizedText(
        es: 'Los ajustes están agrupados en bloques con las descargas primero y cada grupo con su título, para encontrar cada opción de un vistazo.',
        en: 'Settings are grouped in blocks with downloads first and a title for each group, so every option is easy to find at a glance.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1138-video-audio-merge',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.fixes,
      emoji: '🎬',
      order: 0,
      title: LocalizedText(
        es: 'Los vídeos sin audio ya se descargan con sonido',
        en: 'Videos without audio download with sound now',
      ),
      description: LocalizedText(
        es: 'Las calidades que venían sin pista de audio se unen con la mejor pista disponible antes de guardarse, así el archivo nunca acaba mudo.',
        en: 'Qualities that came without an audio track are joined with the best available track before saving, so the file never ends up muted.',
      ),
    ),
    WhatsNewEntry(
      id: 'wn-1138-no-white-flash',
      version: '1.1.38',
      build: 43,
      category: WhatsNewCategory.fixes,
      emoji: '✨',
      order: 1,
      title: LocalizedText(
        es: 'Se acabó el destello blanco al minimizar el vídeo',
        en: 'No more white flash when minimising the video',
      ),
      description: LocalizedText(
        es: 'Al minimizar el vídeo o redimensionar la ventana flotante ya no aparece un fogonazo blanco: la ventana se pinta en negro mientras se recoloca.',
        en: 'Minimising the video or resizing the floating window no longer shows a white flash: the window is painted black while it is being resized.',
      ),
    ),
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
