# 🚀 Guía de Lanzamiento de Actualizaciones Completas de Inútil TV (InútilTV)
> **Documento para Agentes de IA (Qwen Strata, Antigravity) y Desarrolladores**  
> *Nombre oficial de la aplicación:* **Inútil TV** (en código y branding: `InútilTV`)  
> *Ruta del proyecto:* `/home/cesar/Escritorio/alo/tvtv`  
> *Repositorio GitHub:* [`CesarHGlez13/inutil-tv`](https://github.com/CesarHGlez13/inutil-tv)  
> *Identificador técnico de paquete Android (namespace interno):* `dev.cesar.tubotv`  

> [!NOTE]
> La aplicación se llama **Inútil TV** (o **InútilTV**). El identificador `dev.cesar.tubotv` es exclusivamente el namespace interno de Android requerido por el sistema operativo, pero ante el usuario, en la interfaz, en los títulos y en las publicaciones su nombre es **Inútil TV**.  

---

## 🎯 1. Filosofía y Reglas de Oro

1. **NUNCA compilar APK universal pesado:**  
   Siempre usar `--split-per-abi`. Un APK universal pesa más de 75 MB y agota la RAM en TV Boxes de 1.5 GB / 2 GB como la Onn 4K. El split genera APKs optimizados de ~36 MB (`armeabi-v7a`), ~41 MB (`arm64-v8a`) y ~47 MB (`x86_64`).
2. **Sincronización Obligatoria en 3 archivos:**  
   Si subes la versión en `pubspec.yaml` pero olvidas actualizar `app_info.dart`, **la app mostrará un falso diálogo de actualización a los usuarios en cada inicio**.
3. **Probar siempre en hardware real antes de publicar:**  
   La TV Box Onn 4K de prueba se encuentra en `192.168.100.17:5555`. No asumas que funciona; compruébalo con ADB, mide la CPU y toma captura de pantalla.
4. **Publicación y Distribución Doble:**  
   Toda actualización debe subirse a **GitHub Releases** (que actualiza `release.json` para la detección OTA) y enviarse al chat de **Telegram** de Cesar (`1002362473`).

---

## 🏗️ 2. Arquitectura de Actualizaciones (OTA)

```
┌────────────────────────────────────────────────────────────────────────┐
│                        FLUJO DE ACTUALIZACIÓN                          │
├────────────────────────────────────────────────────────────────────────┤
│ 1. Sincronizar Versión   ──> pubspec.yaml + app_info.dart + CHANGELOG  │
│ 2. Compilar APKs Split   ──> armeabi-v7a (32-bit), arm64-v8a, x86_64   │
│ 3. Validar en Onn 4K     ──> adb install + verificación en vivo + CPU  │
│ 4. Publicar OTA          ──> release.json + GitHub Releases vX.Y.Z     │
│ 5. Distribuir Telegram   ──> Envío automático de APKs al chat privado │
└────────────────────────────────────────────────────────────────────────┘
```

### ¿Cómo detecta la app una actualización?
Al abrirse o al presionar "Buscar actualizaciones", la app consulta:
1. `https://github.com/CesarHGlez13/inutil-tv/releases/latest/download/release.json` (o Firestore `app_config/tv_release`).
2. Compara `manifest['latestVersion']` con `AppInfo.appVersion`.
3. Si `latestVersion > appVersion`, abre el diálogo OTA y descarga automáticamente el APK que coincide con la arquitectura del procesador (`arm64_v8a`, `armeabi_v7a` o `x86_64`).

---

## 📋 3. Los 3 Archivos Sagrados de Versión

Para cualquier versión `X.Y.Z` con build number `N` (ejemplo: `3.3.6+46`):

### 1) `pubspec.yaml` (Línea 4)
```yaml
version: 3.3.6+46
```
*Regla de Version Codes en Gradle:*
- `armeabi-v7a`: `1000 + buildNumber` = `1046`
- `arm64-v8a`: `2000 + buildNumber` = `2046`
- `x86_64`: `4000 + buildNumber` = `4046`

### 2) `lib/constants/app_info.dart` (Línea 7)
```dart
class AppInfo {
  static const String appName = 'InútilTV';
  static const String appVersion = '3.3.6'; // <-- ¡DEBE SER EXACTAMENTE LA MISMA!
```
> [!CRITICAL]
> Si este valor queda en una versión anterior, la app creerá estar desactualizada en cuanto descargue el nuevo `release.json`.

### 3) `CHANGELOG.md`
Agrega la nueva versión al principio del archivo:
```markdown
## [3.3.6] - 2026-11-18
- Descripción clara y concisa de la mejora 1.
- Descripción de la corrección de errores 2.
- Mejoras de rendimiento en reproducción.
```
*`tool/publish_release.sh` lee automáticamente esta sección para poblar el release en GitHub y el campo `releaseNotes` de `release.json`.*

---

## ⚡ 4. Método Rápido: Pipeline Todo-en-Uno (Recomendado para Agentes)

Hemos creado un script que realiza todas las validaciones, compilación, prueba en la TV Box, publicación en GitHub y envío por Telegram:

```bash
cd /home/cesar/Escritorio/alo/tvtv
bash tool/full_release_pipeline.sh 3.3.6
```

### Opciones del Script:
| Opción | Descripción |
|---|---|
| *(sin opciones)* | Compila, valida en Onn 4K, publica en GitHub y envía a Telegram. |
| `--urgent` o `--mandatory` | Marca la actualización como obligatoria (bloquea la versión anterior hasta actualizar). |
| `--skip-tv-test` | Omite la instalación y prueba en la TV Box Onn 4K (si la box está apagada). |
| `--skip-build` | No re-compila los APKs (útil si ya corriste `flutter build` previamente). |
| `--skip-telegram` | Omite el envío por Telegram. |

---

## 🛠️ 5. Método Manual Paso a Paso (Para Control Quirúrgico)

Si Qwen Strata o el desarrollador necesitan ejecutar cada paso manualmente:

### Paso 1: Análisis Estático de Código
Verificar que no existan errores ni advertencias de compilación:
```bash
cd /home/cesar/Escritorio/alo/tvtv
export PATH="$PATH:/snap/bin"
flutter analyze --no-fatal-infos
```
*(Debe terminar con `No issues found!`)*

### Paso 2: Compilación de APKs Release Divididos por Arquitectura
```bash
flutter build apk --release --split-per-abi
```
Verifica que existan en `build/app/outputs/flutter-apk/`:
- `app-armeabi-v7a-release.apk` (~36 MB)
- `app-arm64-v8a-release.apk` (~41 MB)
- `app-x86_64-release.apk` (~47 MB)

### Paso 3: Instalación y Prueba en la TV Box (Onn 4K)
*Dispositivo:* `192.168.100.17:5555` (SoC Amlogic s4, 32-bit `armeabi-v7a`).

```bash
export ADB=/home/cesar/Android/Sdk/platform-tools/adb
$ADB connect 192.168.100.17:5555

# Instalar versión armeabi-v7a
$ADB -s 192.168.100.17:5555 install -r -d -g build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk

# Verificar versión instalada
$ADB -s 192.168.100.17:5555 shell dumpsys package dev.cesar.tubotv | grep -E "versionCode|versionName"

# Reiniciar la app
$ADB -s 192.168.100.17:5555 shell am force-stop dev.cesar.tubotv
$ADB -s 192.168.100.17:5555 shell am start -W -n dev.cesar.tubotv/.MainActivity

# Tomar captura de pantalla de verificación
$ADB -s 192.168.100.17:5555 exec-out screencap -p > /tmp/tv_screen_verify.png
```

### Paso 4: Publicar Release OTA en GitHub y Firestore
```bash
# Lanzamiento normal (opcional para el usuario):
bash tool/publish_release.sh 3.3.6 --github

# O si es urgente/obligatoria:
bash tool/publish_release.sh 3.3.6 --github --urgent
```
*Este comando:*
1. Calcula los hashes SHA-256 y tamaños exactos de cada APK.
2. Genera el archivo `release.json`.
3. Sube los APKs y `release.json` a GitHub Releases mediante `gh release create`.
4. Actualiza Firestore en `projects/inutil-music-app/databases/(default)/documents/app_config/tv_release` si hay token disponible.

### Paso 5: Enviar los APKs al Telegram de Cesar
```bash
python3 tool/send_release_telegram.py 3.3.6
```
*Lee el bot token desde `/home/cesar/.hermes/.env` (`TELEGRAM_BOT_TOKEN`) y envía los dos APKs principales (`arm64-v8a` y `armeabi-v7a`) con sus notas al chat `1002362473`.*

---

## 🔑 6. Rutas de Entorno y Credenciales del Sistema

| Recurso | Ruta / Valor | Propósito |
|---|---|---|
| **Flutter SDK** | `/snap/bin/flutter` | Compilación y análisis de Flutter |
| **Android ADB** | `/home/cesar/Android/Sdk/platform-tools/adb` | Control e instalación remota en TV |
| **IP TV Box** | `192.168.100.17:5555` | Dispositivo de pruebas Onn 4K |
| **Keystore Release** | `android/app/tubotv-release.keystore` | Firma de los APKs (`alias: tubotv`) |
| **Token Telegram** | `/home/cesar/.hermes/.env` | Clave `TELEGRAM_BOT_TOKEN` |
| **Chat Telegram** | `1002362473` | Chat personal de Cesar |
| **GitHub CLI** | `gh` (autenticado) | Subida de releases a `CesarHGlez13/inutil-tv` |

---

## 🩺 7. Diagnóstico de Problemas Típicos (Troubleshooting)

### A. La app muestra "Actualización disponible" apenas se abre
- **Causa:** `lib/constants/app_info.dart` tiene un número de versión inferior al de `pubspec.yaml` o `release.json`.
- **Solución:** Cambia `appVersion = 'X.Y.Z'` en `app_info.dart` para que coincida exactamente con la nueva versión lanzada, recompila e instala.

### B. El video de películas o TV en vivo se traba en la TV Box
- **Causa:** Colisión de decodificadores hardware en el chip Amlogic s4 (2 reproductores abiertos a la vez) o uso de escaladores pesados.
- **Solución:**
  1. Verificar que `FullscreenPlaybackCoordinator.instance.isActive` esté liberando `TvScreen` al entrar a VOD.
  2. Verificar que mpv use escaladores rápidos: `cscale=bilinear`, `dscale=bilinear`, `sws-scaler=fast_bilinear`.

### C. `gh release create` falla por tag existente
- Si necesitas re-subir la misma versión, usa `gh release upload vX.Y.Z ... --clobber` o borra el tag previo con `gh release delete vX.Y.Z --yes`.

### D. ADB dice `device offline` o `connection refused`
- Ejecuta:
  ```bash
  adb disconnect
  adb kill-server
  adb start-server
  adb connect 192.168.100.17:5555
  ```
