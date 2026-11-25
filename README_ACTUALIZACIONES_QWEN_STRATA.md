# Guía Compacta de Desarrollo y Lanzamiento (Qwen Strata / Agentes)

> **App Oficial:** **Inutix TV** (ecosistema **inutix.com** junto con **Inutix Music** / **Familia Inutix**)
> **Package ID Android:** `dev.cesar.tubotv` *(namespace interno; NO cambiar para no romper OTAs)*
> **Repo:** `/home/cesar/Escritorio/alo/tvtv` → `CesarHGlez13/inutil-tv` (rama `main`)
> **Versión base actual:** `3.3.40+89`

---

## Reglas Críticas (No Romper)

1. **Marca visible:** usar siempre **Inutix TV**, **Inutix Music** y **Familia Inutix** (nunca `InútilTV`, `Inútil Music` ni `tubotv` en UI).
2. **Aislamiento de proyectos y dispositivos:**
   - **NUNCA** modificar archivos dentro de `/home/cesar/Escritorio/alo/inutil_music`.
   - **NUNCA** instalar APKs en el Galaxy S7 Edge (`ad09160360308ca38a`) — es el servidor SQLite autoritativo de `api.inutix.com`.
   - Instalar solo en Onn 4K TV Box (`192.168.100.17:5555`, `armeabi-v7a`) y celular de pruebas (`arm64-v8a`).
3. **Cero llaves/secretos en el repo ni en el APK:** `api.inutix.com` (S7) y `backup.inutix.com` (failover) manejan datos; `meta.inutix.com` guarda TMDB/Fanart en Cloudflare; `ota.inutix.com` espeja `release.json` y APKs. Las credenciales locales viven fuera del repo (`~/.config/inutil_relay/admin_secret.txt`, `~/.hermes/.env`).
4. **Changelogs 100% a nivel usuario:** las notas en `CHANGELOG.md` y `AppInfo.whatsNewHighlights` deben describir beneficios claros para el usuario final (sin menciones de panel admin, Firestore, SQLite, scripts internos ni llaves).
5. **Sincronizar siempre 3 archivos antes de compilar:**
   - `pubspec.yaml` (`version: X.Y.Z+N`)
   - `lib/constants/app_info.dart` (`appVersion = 'X.Y.Z'`)
   - `CHANGELOG.md` (`## X.Y.Z — YYYY-MM-DD`) + pins de versión en `test/v3_3_22_crunchyroll_detail_test.dart`, `test/v3_3_23_crunchyroll_tv_test.dart`, `test/v3_3_24_artwork_and_tv_hero_test.dart`.

---

## Ahorro de Contexto (Obligatorio para Qwen Strata)

Varios archivos superan 1,100 líneas (`main.dart`, `vod_detail_modal.dart`, `inutil_auth_gate.dart`, `cuevana_poseidon_service.dart`, `firebase_auth_service.dart`). **NO leas archivos completos**: usa `grep -n` primero y lee solo bloques de 60–150 líneas.

| Área | Archivo principal |
| :--- | :--- |
| Marca, versión, novedades | `lib/constants/app_info.dart` |
| Navegación móvil/TV, barra superior | `lib/main.dart` |
| Infra `inutix.com` y failover LAN→api→backup | `lib/services/firebase_config.dart`, `lib/services/firebase_firestore_service.dart` |
| Mirrors VOD dinámicos (`app_config/providers`) | `lib/services/remote_providers_config.dart` |
| Red, proxy sistema Android, DoH y diagnóstico | `lib/services/network_config_service.dart`, `android/.../MainActivity.kt` |
| Streaming Películas / Series / Anime | `lib/services/cuevana_poseidon_service.dart`, `serieskao_service.dart`, `jkanime_service.dart`, `tioanime_service.dart` |
| Validación HLS, proxy adaptativo, reproductor | `lib/services/stream_validator.dart`, `hls_stream_proxy.dart`, `lib/screens/player_screen.dart` |
| Logos PNG vía `meta.inutix.com/logo` | `lib/services/title_logo_service.dart` |
| OTA y respaldo `ota.inutix.com` | `lib/services/inutil_update_service.dart`, `lib/services/ota_download_manager.dart` |
| Control remoto LAN autenticado por cuenta | `lib/services/tv_remote_service.dart`, `lib/widgets/tv_remote_sheet.dart` |
| Ficha detalle Crunchyroll (móvil + TV) | `lib/widgets/vod_detail_modal.dart` |

---

## Comandos Rápidos de Validación y Lanzamiento

```bash
cd /home/cesar/Escritorio/alo/tvtv

# 1. Análisis rápido (filtrando solo errores/warnings para no saturar contexto)
flutter analyze --no-fatal-infos 2>&1 | grep -E "^\s*(error|warning)" || echo "OK"

# 2. Pruebas clave (evitar correr salidas gigantes sin filtrar)
python3 tool/test_relay_invalidate.py
flutter test -r compact test/v3_3_36_user_changelog_and_system_proxy_test.dart test/v3_3_34_inutix_rebrand_and_zero_secrets_test.dart test/v3_3_33_cloudflare_edge_and_remote_providers_test.dart test/v3_3_32_stream_resilience_test.dart

# 3. Pipeline completo (split-per-abi + relay horneado + ADB sin S7 + GitHub + api/backup.inutix.com + Telegram)
bash tool/full_release_pipeline.sh <VERSION> --urgent
```

*(Si la TV Box `192.168.100.17` no responde por Ethernet, enrutar por Wi-Fi: `sudo ip route add 192.168.100.17/32 dev wlp6s0 2>/dev/null || true`.)*

---

## Notas de Sincronía Externa (Cambios aplicados desde auditoría Familia Inutix — 2026-11-24)

> **Importante para la conversación de Inutix TV:** estos cambios ya fueron **commiteados, pusheados a `origin/main` y publicados como OTA obligatoria `v3.3.40+89`** (`mandatory: true`, `minSupportedVersion: "3.3.40"`) para resolver de inmediato el bloqueo de sesiones en cuentas autorizadas. La siguiente release de Inutix TV debe partir de `3.3.41+90`.

1. **Corrección de «Sesión bloqueada / Tu cuenta fue eliminada» en cuentas autorizadas:**
   - Se añadió `FirebaseConfig.directFirestoreBaseUrl` + `InutilFirestoreService.getDocumentDirect()` / `getUserProfileDirect()`.
   - `InutilAuthService._fetchVerifiedUserProfile()` hace doble verificación directa contra Google Firestore antes de aceptar un `404` proveniente de un relay/respaldo (`api.inutix.com` / `backup.inutix.com`).
   - `InutilAuthService._reconcileRemoteProfile()` limpia `_kickedOutReason` automáticamente al recuperar un perfil válido (en validación periódica y en el botón **Comprobar Estado**).
2. **Panel de Control VIP (`inutil_admin_panel.dart` + `firebase_auth_service.dart`):**
   - Auditado OK: `adminCreateUser`, `adminGrantVigencia`, `adminSetExactExpiration` y `adminToggleUserActive` escriben a `users/{uid}` en `api.inutix.com`, que desde hoy también espeja automáticamente a Google Firestore (`RELAY_USER_PROFILE_MIRROR=1` en el S7 Edge).
   - Mejora añadida: `adminGrantVigencia` y `adminToggleUserActive(isActive: true)` ahora también actualizan `lastActiveAt: DateTime.now()` para levantar de inmediato cualquier pausa por inactividad al autorizar/reactivar una cuenta VIP.
