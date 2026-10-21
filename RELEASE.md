# Publicar una actualizacion de VibeGrab

Guia corta y **a prueba de cambios de equipo**. Publicar una version no depende
de ningun portatil concreto: lo hace GitHub Actions.

---

## Resumen

| Paso | Que hacer |
|------|-----------|
| 1 | Subir la version en 3 sitios |
| 2 | Anadir las novedades (catalogo) |
| 3 | Escribir las notas del release (`docs/releases`) |
| 4 | Commit + push a `main` |
| 5 | Crear y empujar el tag `vX.Y.Z-B` |
| 6 | GitHub Actions compila, firma y publica el APK solo |

---

## 1. Subir la version

- `mobile/pubspec.yaml` -> `version: X.Y.Z+B`  (semver de tres; `B` es el
  `versionCode`)
- **No uses cuatro componentes** (`X.Y.Z.P`) para una versión publicada. Las
  apps ya instaladas y la web solo reconocen `X.Y.Z`: un tag `v1.1.40.2-47`
  no aparece como actualización. Para un parche usa el siguiente número
  normal, por ejemplo `1.1.41`.
- **El número de build (`B`) SIEMPRE sube**, aunque la versión no cambie:
  Android solo deja instalar un APK cuyo `versionCode` es mayor que el que
  ya hay instalado. Un parche sobre la misma versión es un tag con la misma
  `X.Y.Z` y un `B` nuevo (`v1.1.42-50`); si se repite un `B` ya publicado,
  Android rechaza la instalación con `INSTALL_FAILED_VERSION_DOWNGRADE` y el
  instalador se abre y se cierra sin decir nada.
- `mobile/lib/core/localization/app_es.arb` -> `"appVersion": "vX.Y.Z"`
- `mobile/lib/core/localization/app_en.arb` -> `"appVersion": "vX.Y.Z"`

## 2. Anadir las novedades

En `mobile/lib/features/whats_new/data/whats_new_catalog.dart`, copia el bloque
mas reciente y ajusta `version: 'X.Y.Z'`, `build: B` y los textos `es`/`en`.

Reglas:
- Solo cambios **reales** (nada de promesas).
- Nunca commits, nombres de archivos, clases ni detalles internos.
- Cada novedad va a una categoria: `features`, `improvements`, `fixes`, `stability`.
- La pantalla "Novedades" y el catalogo son la unica fuente de lo que ve el usuario.

## 3. Notas del release

Crea `docs/releases/X.Y.Z.md` — **sin el build y sin la `v` del tag**
(`v1.1.38-43` -> `docs/releases/1.1.38.md`; el workflow corta el build para
formar el nombre y no encuentra `v1.1.38.md`) — con esas mismas novedades, en el
formato `## Seccion` + `- **Titulo** — descripcion`, con los dos idiomas
separados por los marcadores `<!-- es -->` y `<!-- en -->`. Copia el bloque mas
reciente del catalogo y conviertelo a texto.

Para que? El catalogo viaja **dentro** del binario, asi que la app instalada
solo conoce las versiones que ya tenia: la **primera** actualizacion que ve un
usuario llega sin catalogo y lo unico que puede enseñar es el texto del
release. Sin ese archivo, GitHub rellena el release con la lista de commits,
que es una lista de cambios tecnica y no algo para quien usa la app.

Si el archivo falta, el workflow **falla antes de publicar** y dice que falta:
asi nunca sale un release con la lista de commits como texto.

## 4. Commit y push

```bash
git checkout main
git merge <rama-de-trabajo>
git push origin main
```

> `main` despliega el backend en Render. El APK **no** se genera con esto.

## 5. Tag (formato EXACTO)

```bash
git tag vX.Y.Z-B
git push origin vX.Y.Z-B
```

El formato es `vX.Y.Z-B`: la app y la web lo leen con
`^v(\d+)\.(\d+)\.(\d+)-(\d+)$`. Ejemplo: `v1.1.41-48`. El workflow toma el
`versionName` del tag (`1.1.41`) y el `versionCode` del build (`48`). No uses
cuatro componentes para una versión que deba recibir alguien que ya tiene una
versión anterior instalada.

## 6. Compilacion y publicacion

### Opcion A - GitHub Actions (unica recomendada)

Al empujar el tag, `.github/workflows/release-apk.yml`:
1. instala Java 17 + Flutter 3.47.7,
2. inyecta la clave de firma **desde los secretos del repositorio**,
3. ejecuta los tests,
4. compila `flutter build apk --release`,
5. **verifica la firma** (falla si no es la clave de VibeGrab o si la huella
   no coincide con `ANDROID_CERT_SHA256`),
6. adjunta el APK como `VibeGrab.apk` al release del tag.

No hay que hacer nada mas. Si cualquier paso falla, **no se publica** (los
usuarios nunca ven una actualizacion rota).

### Opcion B - e n local (solo para pruebas)

Necesita `mobile/android/key.properties` (ver "Firma del APK"):

```bash
cd mobile
flutter build apk --release --build-name=1.1.41 --build-number=48
```

---

## Publicidad (Google AdMob)

El SDK oficial `google_mobile_ads` ya esta integrado, pero **la monetizacion
real esta pendiente de configuracion**. No hay identificadores reales en el
repositorio y no se deben inventar.

### Que hace hoy la app

- En **debug** usa los identificadores de prueba oficiales de Google. No
  generan ingresos y no deben presentarse como ganancias.
- En **release** la publicidad queda **desactivada** salvo que se aporten IDs
  reales al compilar. Asi nunca se muestran anuncios de prueba a usuarios.
- Un banner adaptativo compartido puede aparecer en Inicio/Explorar, navegador,
  descargas (solo sin descargas activas) y biblioteca/historial/favoritos.
- No hay anuncios en Analizador, Ajustes, reproductor de audio/video, PiP ni
  controles multimedia.
- Los banners no se recargan por reconstrucciones de widgets ni por cambiar de
  pestana; se reutiliza el mismo objeto cargado.
- Los intersticiales estan implementados en el proveedor y la politica, pero
  **no se disparan automaticamente**: VibeGrab no tiene todavia una transicion
  natural que sea segura para mostrarlos. Limites configurados: 1 cada 10 min,
  3 por sesion, ninguno en los primeros 60 s y ninguno durante reproduccion,
  descargas, PiP o entrada de texto.
- Los anuncios recompensados **no** estan implementados porque el producto no
  tiene una economia de recompensas definida.

### Configuracion pendiente en la consola de AdMob

1. Crear la app Android en AdMob con el package `com.example.vibegrab`.
2. Crear un bloque de anuncios **Banner** para esa app.
3. Opcional: crear un bloque **Intersticial** si se decide activar ese formato
   mas adelante.
4. Crear y publicar un mensaje de consentimiento UMP para las regiones que lo
   requieran. La app ya llama a `ConsentInformation` y ofrece
   "Privacidad y anuncios" en Ajustes cuando la publicidad esta activa y la
   region requiere opciones de privacidad.
5. Copiar el **App ID** (`ca-app-pub-...~...`) y los IDs de bloque
   (`ca-app-pub-.../...`).
6. Verificar la entrega real en un dispositivo/emulador con una build de
   release firmada. Hasta entonces no se puede afirmar que la monetizacion
   funciona.

### Activar en GitHub Actions

En el repositorio, configurar:

| Nombre | Tipo | Valor |
|--------|------|-------|
| `ADMOB_ENABLED` | Variable | `true` |
| `ADMOB_APP_ID` | Secreto | App ID de AdMob |
| `ADMOB_BANNER_ID` | Secreto | ID del banner |
| `ADMOB_INTERSTITIAL_ID` | Secreto opcional | ID del intersticial |

El workflow pasa esos valores a `--dart-define` y a `-PadmobAppId`. Si
`ADMOB_ENABLED=true` falta el App ID o el banner, el build **falla antes de
publicar**. Sin esos valores, el APK de release se publica sin publicidad.

### Activacion manual (solo pruebas)

```bash
cd mobile
flutter build apk --release \
  --dart-define=ADMOB_ENABLED=true \
  --dart-define=ADMOB_BANNER_ID=ca-app-pub-XXXXXXXX/YYYYYYYY \
  --dart-define=ADMOB_INTERSTITIAL_ID=ca-app-pub-XXXXXXXX/ZZZZZZZZ \
  -PadmobAppId=ca-app-pub-XXXXXXXX~WWWWWWWW
```

`google_mobile_ads` 9.1.0 exige `minSdk 24` y `compileSdk 36`; el proyecto ya
los fija. El App ID de prueba se usa por defecto en el manifiesto si no se pasa
uno real.

### Privacidad y limitaciones

- El consentimiento UMP se pide antes de que VibeGrab inicialice el SDK. Si
  falla o el usuario no da consentimiento, no se solicitan anuncios.
- El provider `com.google.android.gms.ads.MobileAdsInitProvider` va
  **desactivado** en el manifest (`android:enabled="false"`). Por defecto el
  SDK de Google Ads se inicializa al arrancar el proceso, antes de Flutter y
  antes del consentimiento UMP: en dispositivos sin Google Play Services esa
  inicializacion lanza una excepcion y **la app se cierra al abrirla**. Con el
  provider desactivado, el SDK solo se inicializa desde Dart, con el
  consentimiento ya dado y solo si la publicidad esta activada.
- `AdMetrics` solo guarda eventos locales y acotados (solicitud, carga,
  impresion, clic, fallo). No envia URLs, busquedas, historial ni identificadores
  y no estima ingresos.
- El SDK de AdMob puede acceder al ID de publicidad y declara el permiso
  `com.google.android.gms.permission.AD_ID` (Android 13+). Hay que reflejarlo en
  la seccion de seguridad de datos de Play Console y respetar la eleccion de
  consentimiento. VibeGrab no lee ese ID directamente.
- Los fallos del proveedor se gestionan con backoff y la app sigue funcionando.
- El navegador **no** bloquea todos los anuncios de terceros: `webview_flutter`
  solo controla navegaciones, no subrecursos. La publicidad propia de VibeGrab
  vive en la interfaz y es independiente de ese filtrado.
- AdMob puede requerir pasos adicionales (por ejemplo `app-ads.txt`) para
  completar la verificacion de la cuenta. No se ha publicado ninguno.

---

## Firma del APK (MUY IMPORTANTE)

La clave de firma **no esta en el repositorio**. Vive en los **secretos de
GitHub Actions** y se inyecta al compilar. Asi:

- el repo puede ser publico sin exponer la clave,
- cualquiera de tus equipos (o ninguno) puede publicar,
- nadie puede firmar APKs falsos que se instalen encima de los tuyos.

### Secretos requeridos

| Secreto | Contenido |
|---------|-----------|
| `ANDROID_KEYSTORE_BASE64` | el `.jks` completo, en base64 |
| `ANDROID_KEYSTORE_PASSWORD` | contrasena del keystore |
| `ANDROID_KEY_PASSWORD` | contrasena de la clave |
| `ANDROID_KEY_ALIAS` | alias (por defecto `vibegrab`) |
| `ANDROID_CERT_SHA256` | huella SHA-256 esperada (verificacion) |

### Configurarlos o rotarlos desde cualquier PC

```powershell
python -m pip install pynacl        # una sola vez
powershell -File tools/set-signing-secrets.ps1 -Keystore C:\ruta\vibegrab.jks
```

El script lee las contrasenas de `key.properties` (o te las pide), calcula la
huella y sube los 5 secretos cifrados con la clave publica del repo.

### Copia de seguridad de la clave (IMPRESCINDIBLE)

Guarda el `.jks` y sus contrasenas en un **gestor de contrasenas o nube
privada**. Si se pierde la clave, TODOS los usuarios tendran que desinstalar
para poder actualizar (fue lo que paso el 17/10/2026).

### Compilar en local (desarrollo)

Copia `mobile/android/key.properties.example` a `key.properties` y rellena los
valores. Ese archivo y los `.jks`/`.keystore` estan en `.gitignore`.

### Historial de firmas

| Versiones | Clave | Nota |
|-----------|-------|------|
| <= 1.1.34 | debug del equipo antiguo (perdida) | incompatible |
| >= 1.1.35 | `vibegrab-release` (SHA-256 `60dfc7ed...`) | los usuarios de <=1.1.34 reinstalan UNA vez |

---

## Comprobaciones rapidas antes de publicar

```bash
cd mobile
flutter analyze          # sin errores
flutter test             # todo en verde
```

Y que el tag coincida con `pubspec.yaml` en `X.Y.Z+B`. El `versionName` debe
tener tres componentes para que las apps instaladas y la web lo detecten.
