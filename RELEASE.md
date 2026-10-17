# Publicar una actualizacion de VibeGrab

Guia corta y a prueba de cambios de equipo. El objetivo es que **cualquier
portatil** pueda publicar una version sin pasos manuales fragiles.

---

## Resumen

| Paso | Que hacer |
|------|-----------|
| 1 | Subir la version en 3 sitios |
| 2 | Anadir las novedades (catalogo) |
| 3 | Commit + push a `main` |
| 4 | Crear y empujar el tag `vX.Y.Z-B` |
| 5 | GitHub Actions compila, firma y publica el APK solo |

---

## 1. Subir la version

- `mobile/pubspec.yaml` -> `version: X.Y.Z+B`  (es la fuente de `versionName`/`versionCode`)
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

## 3. Commit y push

```bash
git checkout main
git merge <rama-de-trabajo>
git push origin main
```

> `main` despliega el backend en Render. El APK **no** se genera con esto.

## 4. Tag (formato EXACTO)

```bash
git tag vX.Y.Z-B
git push origin vX.Y.Z-B
```

El formato `vX.Y.Z-B` es obligatorio: la app lo lee con
`^v(\d+)\.(\d+)\.(\d+)-(\d+)$`. Ejemplo: `v1.1.35-40`.

## 5. Compilacion y publicacion

### Opcion A - GitHub Actions (recomendada, escalable)

Al empujar el tag, el workflow `.github/workflows/release-apk.yml`:
1. instala Java 17 + Flutter 3.47.7,
2. ejecuta los tests,
3. compila `flutter build apk --release`,
4. renombra el APK a `VibeGrab.apk`,
5. lo adjunta al release del tag.

No hay que hacer nada mas. Si el workflow falla, el release no se crea (los
usuarios no ven una actualizacion rota).

### Opcion B - En local (cualquier equipo con Flutter)

```bash
cd mobile
flutter clean
flutter build apk --release
# subir el APK renombrado:
gh release create vX.Y.Z-B mobile/build/app/outputs/flutter-apk/app-release.apk#VibeGrab.apk \
  --title vX.Y.Z-B --generate-notes
```

---

## Firma del APK (MUY IMPORTANTE)

- Keystore: `mobile/android/keystore/vibegrab-release.jks`
- Credenciales: `mobile/android/key.properties` (alias `vibegrab`)
- Gradle las lee automaticamente (`mobile/android/app/build.gradle.kts`).
- Si falta el archivo, cae a la clave `debug` (solo para desarrollo).

> **Esta clave SI se versiona a proposito.** El 17/10/2026 se perdio la clave
> anterior al formatear el otro portatil, y todos los usuarios habrian tenido
> que desinstalar. Tenerla en el repo garantiza que siempre viaje con el codigo.

Recomendaciones:
- Haz una copia de seguridad aparte (nube o gestor de contrasenas).
- Si algun dia se rota la clave, los usuarios deberan reinstalar **una vez**.

### Historial de firmas

| Version | Clave | Nota |
|---------|-------|------|
| <= 1.1.34 | debug (equipo antiguo, perdida) | incompatible con lo nuevo |
| >= 1.1.35 | `vibegrab-release.jks` (en el repo) | los usuarios de <=1.1.34 deberan reinstalar UNA vez |

---

## Comprobaciones rapidas antes de publicar

```bash
cd mobile
flutter analyze          # sin errores
flutter test             # todo en verde
```

Y que el tag coincida con `pubspec.yaml` (`X.Y.Z+B`).
