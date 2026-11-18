# InútilTV — canal de actualizaciones OTA

Repositorio **sólo de artefactos**: aquí se publican las Releases con los
paquetes APK que **InútilTV** descarga e instala desde dentro de la aplicación
(`Ajustes → Buscar actualizaciones (OTA)` y la pantalla de actualización
obligatoria / Kill Switch). El código fuente vive en el repositorio local de la
app y no se publica aquí.

## Contenido de cada Release `v<versión>`

| Asset | Para qué |
| --- | --- |
| `app-arm64-v8a-release.apk` | teléfonos Android ARM de 64 bits (enlace por defecto) |
| `app-armeabi-v7a-release.apk` | teléfonos Android / TV Box ARM de 32 bits |
| `app-x86_64-release.apk` | emuladores / tablets x86_64 |
| `release.json` | manifiesto que lee `InutilUpdateService.checkForUpdate` (`latestVersion`, `minSupportedVersion`, `mandatory`, URLs por ABI, tamaños y SHA-256) |

La app consulta en paralelo el documento Firestore `app_config/tv_release` (que
también se controla en tiempo real desde el **Panel de Administración César**)
y `releases/latest/download/release.json` de este repositorio.

## Publicar una versión

```bash
flutter build apk --release --split-per-abi
bash tool/publish_release.sh <versión> --dry-run
bash tool/publish_release.sh <versión> --github
```
