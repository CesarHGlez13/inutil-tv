#!/usr/bin/env bash
# ==============================================================================
# PIPELINE COMPLETO DE LANZAMIENTO DE ACTUALIZACIONES PARA INÚTILTV
# Diseñado para ejecución por agentes autónomos (Qwen Strata, Antigravity, etc.)
# ==============================================================================
# Uso:
#   bash tool/full_release_pipeline.sh <VERSION> [OPCIONES]
#
# Opciones:
#   --skip-build     Omite la compilación con flutter build (si ya se compilaron)
#   --skip-tv-test   Omite la prueba e instalación en la TV Box Onn 4K
#   --urgent         Marca la actualización como forzosa/obligatoria en OTA
#   --skip-telegram  Omite el envío de APKs por Telegram
#
# Ejemplo:
#   bash tool/full_release_pipeline.sh 3.3.6
# ==============================================================================
set -euo pipefail

PROY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROY"
export PATH="$PATH:/snap/bin:/home/cesar/Android/Sdk/platform-tools"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "❌ Error: Especifica la versión. Ejemplo: bash tool/full_release_pipeline.sh 3.3.6" >&2; exit 1; }
shift || true

SKIP_BUILD=0
SKIP_TV_TEST=0
URGENT_FLAG=""
SKIP_TELEGRAM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-tv-test) SKIP_TV_TEST=1 ;;
    --urgent|--mandatory) URGENT_FLAG="--urgent" ;;
    --skip-telegram) SKIP_TELEGRAM=1 ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "=================================================================="
echo "🚀 INICIANDO PIPELINE DE ACTUALIZACIÓN COMPLETO: InútilTV v$VERSION"
echo "=================================================================="

# --- 1. Verificación de Sincronización de Versión ---
echo "▶ [1/6] Verificando sincronización de versión en código fuente..."

PUBSPEC_VER="$(grep -E '^version:\s*' pubspec.yaml | sed -E 's/version:\s*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
APP_INFO_VER="$(grep -E "appVersion\s*=" lib/constants/app_info.dart | sed -E "s/.*'([0-9]+\.[0-9]+\.[0-9]+)'.*/\1/")"

if [ "$PUBSPEC_VER" != "$VERSION" ]; then
  echo "❌ ERROR: pubspec.yaml tiene versión '$PUBSPEC_VER', pero se solicitó '$VERSION'."
  echo "   Actualiza pubspec.yaml (ej. version: $VERSION+buildNumber) antes de continuar."
  exit 1
fi

if [ "$APP_INFO_VER" != "$VERSION" ]; then
  echo "❌ ERROR: lib/constants/app_info.dart tiene appVersion = '$APP_INFO_VER', pero se solicitó '$VERSION'."
  echo "   Si no se actualiza app_info.dart, la app mostrará un falso diálogo de actualización a los usuarios."
  exit 1
fi

if ! grep -qE "^##\s*\[?$VERSION\b" CHANGELOG.md; then
  echo "⚠️ AVISO: No se encontró sección '## [$VERSION]' en CHANGELOG.md."
  echo "   Es altamente recomendado agregar las notas de la versión en CHANGELOG.md."
fi
echo "✅ Versiones sincronizadas correctamente ($VERSION)."

# --- 2. Análisis Estático ---
echo "▶ [2/6] Ejecutando análisis estático (flutter analyze)..."
flutter analyze --no-fatal-infos

# --- 3. Compilación Release Split-Per-ABI ---
APK_DIR="$PROY/build/app/outputs/flutter-apk"
if [ "$SKIP_BUILD" = "0" ]; then
  echo "▶ [3/6] Compilando APKs split-per-abi release v$VERSION (con relay horneado S7)..."
  flutter build apk --release --split-per-abi --dart-define=FB_RELAY_HOST=192.168.100.27
else
  echo "▶ [3/6] Omitiendo compilación (--skip-build)."
fi

[ -f "$APK_DIR/app-armeabi-v7a-release.apk" ] || { echo "❌ Falta app-armeabi-v7a-release.apk" >&2; exit 1; }
[ -f "$APK_DIR/app-arm64-v8a-release.apk" ] || { echo "❌ Falta app-arm64-v8a-release.apk" >&2; exit 1; }
echo "✅ APKs listos en $APK_DIR:"
ls -lh "$APK_DIR"/app-*-release.apk

# --- 4. Prueba e Instalación en Dispositivos Físicos ---
DEV_TV="${DEV_TV:-192.168.100.17:45741}"
if [ "$SKIP_TV_TEST" = "0" ]; then
  echo "▶ [4/6] Verificando e instalando en dispositivos físicos ADB..."
  
  # A. TV Box Onn 4K (armeabi-v7a)
  # Intentar puerto configurado (ej. 45741) o fallback a 5555
  TV_CONNECTED=0
  for tv_endpoint in "$DEV_TV" "192.168.100.17:45741" "192.168.100.17:5555"; do
    if timeout 4 adb connect "$tv_endpoint" >/dev/null 2>&1 && adb -s "$tv_endpoint" get-state 2>/dev/null | grep -q "device"; then
      DEV_TV="$tv_endpoint"
      TV_CONNECTED=1
      break
    fi
  done

  if [ "$TV_CONNECTED" = "1" ]; then
    echo "Instalando versión armeabi-v7a en TV Box Onn 4K ($DEV_TV)..."
    adb -s "$DEV_TV" install -r -d -g "$APK_DIR/app-armeabi-v7a-release.apk"
    INSTALLED_VER="$(adb -s "$DEV_TV" shell dumpsys package dev.cesar.tubotv | grep -E "versionName=" | head -1 | tr -d ' \r')"
    echo "Instalación en TV Box completada: $INSTALLED_VER"
    adb -s "$DEV_TV" shell am force-stop dev.cesar.tubotv
    sleep 1
    adb -s "$DEV_TV" shell am start -W -n dev.cesar.tubotv/.MainActivity >/dev/null
    echo "✅ App iniciada correctamente en Onn 4K."
  else
    echo "⚠️ TV Box no responde en $DEV_TV ni en puerto 5555 (puede estar en suspensión)."
  fi

  # B. Celular Android conectado (arm64-v8a / auto-detección, excluyendo relay S7)
  CONNECTED_DEVS="$(adb devices | grep -E '\s+device$' | grep -v "$DEV_TV" | grep -v "ad09160360308ca38a" | awk '{print $1}' || true)"
  for dev_id in $CONNECTED_DEVS; do
    DEV_ABI="$(adb -s "$dev_id" shell getprop ro.product.cpu.abi | tr -d ' \r')"
    DEV_MODEL="$(adb -s "$dev_id" shell getprop ro.product.model | tr -d ' \r')"
    echo "Detectado dispositivo móvil: $dev_id ($DEV_MODEL, ABI: $DEV_ABI)"
    TARGET_APK=""
    if [[ "$DEV_ABI" =~ "arm64" ]]; then
      TARGET_APK="$APK_DIR/app-arm64-v8a-release.apk"
    elif [[ "$DEV_ABI" =~ "armeabi" ]]; then
      TARGET_APK="$APK_DIR/app-armeabi-v7a-release.apk"
    fi
    if [ -n "$TARGET_APK" ] && [ -f "$TARGET_APK" ]; then
      echo "Instalando $(basename "$TARGET_APK") en $dev_id..."
      adb -s "$dev_id" install -r -d -g "$TARGET_APK"
      PHONE_VER="$(adb -s "$dev_id" shell dumpsys package dev.cesar.tubotv | grep -E "versionName=" | head -1 | tr -d ' \r')"
      echo "✅ Dispositivo móvil $dev_id actualizado: $PHONE_VER"
    fi
  done
else
  echo "▶ [4/6] Prueba física en dispositivos omitida (--skip-tv-test)."
fi

# --- 5. Publicación OTA (GitHub Releases + Firestore) ---
echo "▶ [5/6] Publicando Release OTA v$VERSION en GitHub Releases..."
bash tool/publish_release.sh "$VERSION" --github $URGENT_FLAG

# --- 6. Envío de APKs a Telegram ---
if [ "$SKIP_TELEGRAM" = "0" ]; then
  echo "▶ [6/6] Enviando APKs a Telegram..."
  python3 tool/send_release_telegram.py "$VERSION"
else
  echo "▶ [6/6] Envío a Telegram omitido (--skip-telegram)."
fi

echo "=================================================================="
echo "🎉 ACTUALIZACIÓN v$VERSION LANZADA Y DISTRIBUIDA CON ÉXITO"
echo "=================================================================="
