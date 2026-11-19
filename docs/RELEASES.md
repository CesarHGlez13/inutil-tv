# Publicar una versión de InútilTV (OTA + Forzar OTA)

## Flujo automático en 1 comando

1. Sube la versión en `pubspec.yaml` (`version: 2.0.1+21`) y en `lib/constants/app_info.dart` (`appVersion = '2.0.1'`).
2. Agrega las novedades en `CHANGELOG.md` bajo `## 2.0.1`.
3. Compila los APKs divididos por arquitectura:
   ```bash
   flutter build apk --release --split-per-abi
   ```
4. Publica automáticamente en GitHub Releases (`CesarHGlez13/inutil-tv`) y sincroniza Firestore (`app_config/tv_release`):
   ```bash
   bash tool/publish_release.sh 2.0.1 --github
   ```
   - Por defecto activa `mandatory: true` y `minSupportedVersion: <versión>` (OTA Forzosa / Kill Switch).
   - Para publicar una actualización **opcional** (no bloqueante):
     ```bash
     MANDATORY=0 MIN_SUPPORTED=2.0.0 bash tool/publish_release.sh 2.0.1 --github
     ```

## Control desde Firebase Web (Consola)

La app de InútilTV es 100% para usuario final (sin panel admin embebido, igual que Inútil Music). Desde la consola web de Firebase (`firestore` → `app_config/tv_release`) o con `tool/publish_release.sh`, puedes cambiar `latestVersion`, `minSupportedVersion`, `mandatory` (Forzar OTA), enlaces APK y notas en tiempo real sin afectar a Inútil Music (`app_config/release`).
