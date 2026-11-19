# Guía Definitiva de Lanzamiento y Actualizaciones para Qwen Strata
> **Aplicación Oficial:** **Inútil TV** (en código y branding: `InútilTV`)  
> **Identificador técnico de paquete (Android ID):** `dev.cesar.tubotv` *(solo namespace interno)*  
> **Directorio del proyecto:** `/home/cesar/Escritorio/alo/tvtv`  
> **Repositorio GitHub:** [`CesarHGlez13/inutil-tv`](https://github.com/CesarHGlez13/inutil-tv)  
> **Destinatario de Telegram:** Cesar (`chat_id=1002362473`)  
> **Dispositivo TV Box de Pruebas:** Onn 4K Streaming Box en `192.168.100.17` (puertos `5555` o `45741`)

---

## 🚨 Reglas Fundamentales para Qwen Strata

1. **El nombre de la aplicación es «Inútil TV» (o «InútilTV»):**  
   NUNCA la llames "tubo tv", "tuvo tv" ni "tubotv". El nombre comercial y visible es **Inútil TV**. El término `tubotv` es únicamente el identificador técnico de paquete requerido por Android (`dev.cesar.tubotv`).

2. **NUNCA compilar APK universal pesado:**  
   Siempre compilar con `--split-per-abi`. Las TV Boxes (como la Onn 4K con SoC Amlogic y 2 GB RAM) colapsan si se instala un APK universal de más de 75 MB. Los APKs divididos pesan:
   - `armeabi-v7a` (32-bit para TV Box Onn 4K): **~35 MB**
   - `arm64-v8a` (64-bit para teléfonos y Fire TV 4K Max): **~39 MB**
   - `x86_64` (emuladores / PC): **~45 MB**

3. **Sincronización OBLIGATORIA de la versión en 3 archivos:**  
   Si subes la versión en `pubspec.yaml` pero no en `lib/constants/app_info.dart`, **la aplicación mostrará un falso diálogo de actualización a los usuarios en cada inicio**.
   - `pubspec.yaml` -> `version: X.Y.Z+N` (ejemplo: `3.3.6+46`)
   - `lib/constants/app_info.dart` -> `static const String appVersion = 'X.Y.Z';`
   - `CHANGELOG.md` -> Sección `## X.Y.Z — YYYY-MM-DD` con las notas del lanzamiento.

4. **Red e Interfaces (Ethernet vs WiFi):**  
   Si la TV Box (`192.168.100.17`) no responde por Ethernet debido a aislamiento de clientes en el módem/router, la ruta debe forzarse por la interfaz WiFi `wlp6s0`:
   ```bash
   sudo ip route add 192.168.100.17/32 dev wlp6s0
   ```

---

## ⚡ El Método Rápido y Automático (Recomendado)

Todo el ciclo (validación, compilación split-per-abi, instalación en TV y celular, publicación en GitHub Releases con `release.json` y envío a Telegram) está automatizado en un solo script:

```bash
cd /home/cesar/Escritorio/alo/tvtv
bash tool/full_release_pipeline.sh <VERSION>
```

**Ejemplo de uso:**
```bash
bash tool/full_release_pipeline.sh 3.3.6
```

### Opciones Disponibles:
- `bash tool/full_release_pipeline.sh 3.3.6 --urgent`: Marca la actualización como obligatoria en Firestore y `release.json` (bloquea versiones anteriores).
- `bash tool/full_release_pipeline.sh 3.3.6 --skip-build`: Si ya corriste `flutter build` previamente y solo quieres publicar e instalar.
- `bash tool/full_release_pipeline.sh 3.3.6 --skip-tv-test`: Omite la instalación en la TV Box si está apagada.
- `bash tool/full_release_pipeline.sh 3.3.6 --skip-telegram`: Omite el envío por Telegram.

---

## 🛠️ Procedimiento Manual Paso a Paso (Si el script falla o se requiere control quirúrgico)

### Paso 1: Actualizar los 3 Archivos de Versión
1. **`pubspec.yaml`**: Modificar la línea 4:
   ```yaml
   version: 3.3.6+46
   ```
   *(El buildNumber se calcula aumentando en +1 el anterior. Gradle genera: armeabi-v7a = 1046, arm64-v8a = 2046).*

2. **`lib/constants/app_info.dart`**:
   ```dart
   static const String appName = 'InútilTV';
   static const String appVersion = '3.3.6';
   ```

3. **`CHANGELOG.md`**: Agregar arriba:
   ```markdown
   ## 3.3.6 — 2026-11-18
   - Descripción de la mejora 1.
   - Descripción de la mejora 2.
   ```

### Paso 2: Análisis Estático y Tests
```bash
cd /home/cesar/Escritorio/alo/tvtv
flutter analyze --no-fatal-infos
flutter test test/v3_3_0_tv_connect_test.dart
```

### Paso 3: Compilar APKs Divididos por ABI
```bash
flutter build apk --release --split-per-abi
```
Generará en `build/app/outputs/flutter-apk/`:
- `app-armeabi-v7a-release.apk`
- `app-arm64-v8a-release.apk`
- `app-x86_64-release.apk`

### Paso 4: Conectar e Instalar en la TV Box y Celular
1. Asegurar ruta hacia la TV:
   ```bash
   sudo ip route add 192.168.100.17/32 dev wlp6s0 2>/dev/null || true
   adb connect 192.168.100.17:5555 || adb connect 192.168.100.17:45741
   ```
2. Instalar en TV Box (32-bit `armeabi-v7a`):
   ```bash
   adb -s 192.168.100.17:5555 install -r -d -g build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
   ```
3. Instalar en Celular (64-bit `arm64-v8a` si está conectado por ADB en `192.168.100.15`):
   ```bash
   adb -s 192.168.100.15:35713 install -r -d -g build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
   ```
4. Reiniciar la app en la TV y verificar versión:
   ```bash
   adb -s 192.168.100.17:5555 shell am force-stop dev.cesar.tubotv
   adb -s 192.168.100.17:5555 shell am start -W -n dev.cesar.tubotv/.MainActivity
   adb -s 192.168.100.17:5555 shell dumpsys package dev.cesar.tubotv | grep -E "versionName|versionCode"
   ```

### Paso 5: Publicar la Release OTA en GitHub
```bash
bash tool/publish_release.sh 3.3.6 --github
```
*Este paso crea el tag `v3.3.6` en GitHub, genera el archivo `release.json` con los hashes SHA-256 de cada APK y actualiza la release.*

### Paso 6: Enviar los APKs al Telegram de Cesar
```bash
python3 tool/send_release_telegram.py 3.3.6
```
*Lee el bot token desde `/home/cesar/.hermes/.env` y envía los APKs listos para descarga al chat `1002362473`.*

---

## 📋 Resumen de Puertos y Credenciales
- **TV Box Onn 4K:** `192.168.100.17:5555` (o puerto dinámico wireless `45741`).
- **Celular Honor / Android:** `192.168.100.15:35713` (puerto dinámico).
- **Keystore de firma:** `android/app/tubotv-release.keystore` (`alias: tubotv`, `pass: tubotv2026`).
- **Telegram Bot Token:** En `/home/cesar/.hermes/.env` (`TELEGRAM_BOT_TOKEN`).
