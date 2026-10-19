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

- `mobile/pubspec.yaml` -> `version: X.Y.Z+B`  (fuente de `versionName`/`versionCode`)
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

Crea `docs/releases/X.Y.Z.md` (sin el build) con esas mismas novedades, en el
formato `## Seccion` + `- **Titulo** — descripcion`, con los dos idiomas
separados por los marcadores `<!-- es -->` y `<!-- en -->`. Copia el bloque mas
reciente del catalogo y conviertelo a texto.

Para que? El catalogo viaja **dentro** del binario, asi que la app instalada
solo conoce las versiones que ya tenia: la **primera** actualizacion que ve un
usuario llega sin catalogo y lo unico que puede enseñar es el texto del
release. Sin ese archivo, GitHub rellena el release con la lista de commits,
que es una lista de cambios tecnica y no algo para quien usa la app.

Si el archivo falta, el workflow cae al texto generado (no rompe nada) y la
app filtra el ruido y pinta lo que quede. Pero lo correcto es escribirlo.

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

El formato `vX.Y.Z-B` es obligatorio: la app lo lee con
`^v(\d+)\.(\d+)\.(\d+)-(\d+)$`. Ejemplo: `v1.1.35-40`.

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
flutter build apk --release
```

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

Y que el tag coincida con `pubspec.yaml` (`X.Y.Z+B`).
