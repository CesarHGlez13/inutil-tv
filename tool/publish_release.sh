#!/usr/bin/env bash
# Publica una versión de InútilTV (OTA + Forzar OTA).
#
# Genera el manifiesto `release.json` y sube los APKs divididos por ABI +
# `release.json` a una Release pública de GitHub (`CesarHGlez13/inutil-tv`) y
# sincroniza el documento Firestore `app_config/tv_release` (sin tocar
# `app_config/release` de Inútil Music).
#
# Uso:
#   bash tool/publish_release.sh 3.2.1 --github            # Opcional por defecto (desde v3.2.0+)
#   bash tool/publish_release.sh 3.2.0 --github --urgent   # Obligatoria (solo actualizaciones urgentes)
#   MIN_SUPPORTED=3.2.0 bash tool/publish_release.sh 3.2.1 --github --urgent
#   bash tool/publish_release.sh 3.2.0 --dry-run
set -euo pipefail

PROY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="${FB_PROJECT:-inutil-music-app}"
RELEASE_REPO="${RELEASE_REPO:-CesarHGlez13/inutil-tv}"
MIN_SUPPORTED="${MIN_SUPPORTED:-}"
# Política desde v3.2.0+: opcional por defecto; solo las marcadas con --urgent / --mandatory son obligatorias.
MANDATORY="${MANDATORY:-0}"

VERSION="${1:-}"; shift || true
MODE="github"; DRY=0; NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --github) MODE="github" ;;
    --urgent|--mandatory) MANDATORY=1 ;;
    --optional) MANDATORY=0 ;;
    --dry-run) DRY=1 ;;
    --notes-file) NOTES_FILE="$2"; shift ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$VERSION" ] || { echo "uso: tool/publish_release.sh <version> [--github] [--urgent|--optional] [--notes-file NOTAS] [--dry-run]" >&2; exit 2; }

APK_DIR="$PROY/build/app/outputs/flutter-apk"
declare -A FILES=()
declare -A ABI_OF_KEY=()
add_artifact() {
  [ -f "$2" ] || return 0
  FILES["$1"]="$2"
  ABI_OF_KEY["$1"]="${3:-}"
}
add_artifact arm64_v8a   "$APK_DIR/app-arm64-v8a-release.apk"   "arm64_v8a"
add_artifact armeabi_v7a "$APK_DIR/app-armeabi-v7a-release.apk" "armeabi_v7a"
add_artifact x86_64      "$APK_DIR/app-x86_64-release.apk"      "x86_64"

if [ ${#FILES[@]} -eq 0 ]; then
  echo "no hay APKs construidos en $APK_DIR (corre flutter build apk --release --split-per-abi)" >&2
  exit 3
fi

if [ -z "$NOTES_FILE" ] && [ -f "$PROY/CHANGELOG.md" ]; then
  NOTES_FILE="$PROY/CHANGELOG.md"
fi

NOTES_JSON='["Mejoras de rendimiento y estabilidad."]'
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
  NOTES_JSON="$(VERSION="$VERSION" CHANGELOG="$NOTES_FILE" python3 - <<'PY'
import json, os, re
version = os.environ["VERSION"]
lines = open(os.environ["CHANGELOG"], encoding="utf-8", errors="replace").read().splitlines()
section_starts = [i for i, l in enumerate(lines) if re.match(r"^##\s+", l)]
chosen = None
for i in section_starts:
    if re.match(r"^##\s*\[?" + re.escape(version) + r"\b", lines[i]):
        chosen = i
        break
if chosen is None and section_starts:
    chosen = section_starts[0]
notes = []
if chosen is not None:
    limit = next((j for j in section_starts if j > chosen), len(lines))
    for line in lines[chosen + 1:limit]:
        t = line.strip()
        if not t or t.startswith("#"):
            continue
        is_bullet = bool(re.match(r"^[-*]\s+", t))
        t = re.sub(r"^[-*]\s+", "", t)
        t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)
        t = re.sub(r"`(.+?)`", r"\1", t)
        if not t:
            continue
        if is_bullet or not notes:
            notes.append(t)
        else:
            notes[-1] = (notes[-1] + " " + t).strip()
        if len(notes) >= 12:
            break
print(json.dumps(notes or ["Mejoras de rendimiento y estabilidad."], ensure_ascii=False))
PY
)"
fi

MANIFEST_DIR="$(mktemp -d)"
trap 'rm -rf "$MANIFEST_DIR"' EXIT
MANIFEST="$MANIFEST_DIR/release.json"
ARTIFACTS_LIST="$MANIFEST_DIR/artifacts.tsv"
: > "$ARTIFACTS_LIST"
for key in $(printf '%s\n' "${!FILES[@]}" | sort); do
  printf '%s\t%s\t%s\n' "$key" "${FILES[$key]}" "${ABI_OF_KEY[$key]:-}" >> "$ARTIFACTS_LIST"
done
printf '%s' "$NOTES_JSON" > "$MANIFEST_DIR/notes.json"

MANIFEST="$MANIFEST" MANIFEST_DIR="$MANIFEST_DIR" VERSION="$VERSION" \
  REPO="$RELEASE_REPO" MIN_SUPPORTED="$MIN_SUPPORTED" MANDATORY="$MANDATORY" \
  python3 - <<'PY'
import datetime, hashlib, json, os, pathlib

manifest_path = pathlib.Path(os.environ["MANIFEST"])
manifest_dir = pathlib.Path(os.environ["MANIFEST_DIR"])
version = os.environ["VERSION"]
repo = os.environ["REPO"]
min_supported = os.environ.get("MIN_SUPPORTED", "").strip()
mandatory = os.environ.get("MANDATORY", "0").strip() not in ("0", "false", "no")
if not min_supported:
    min_supported = version if mandatory else "3.2.0"
notes = json.loads((manifest_dir / "notes.json").read_text())

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()

downloads, sizes, checksums = {}, {}, {}
for line in (manifest_dir / "artifacts.tsv").read_text().splitlines():
    if not line.strip():
        continue
    key, path, abi = (line.split("\t") + [""])[:3]
    if not os.path.exists(path):
        continue
    name = os.path.basename(path)
    size = os.path.getsize(path)
    checksums[name] = sha256(path)
    url = f"https://github.com/{repo}/releases/download/v{version}/{name}"
    downloads[key] = url
    sizes[key] = size
    if abi:
        downloads[abi] = url
        sizes[abi] = size

manifest = {
    "schemaVersion": 1,
    "latestVersion": version,
    "minSupportedVersion": min_supported,
    "mandatory": mandatory,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "apkDownloadUrl": downloads.get("arm64_v8a") or next(iter(downloads.values()), ""),
    "androidDownloads": downloads,
    "androidDownloadSizes": sizes,
    "packageSizeBytes": sizes.get("arm64_v8a") or next(iter(sizes.values()), 0),
    "releaseNotes": notes,
    "checksums": checksums,
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=True, indent=2) + "\n")
PY

echo "=== release.json ==="
cat "$MANIFEST"

if [ "$DRY" = "1" ]; then
  echo "(dry-run: no se subió nada)"
  exit 0
fi

TAG="v$VERSION"
NOTES_MD="$MANIFEST_DIR/notas.md"
python3 - "$MANIFEST" "$NOTES_MD" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
lines = [f"# Inutix TV {m['latestVersion']}", ""]
lines += [f"- {n}" for n in m.get("releaseNotes", [])]
if m.get("mandatory"):
    lines += ["", f"Actualización obligatoria: las versiones anteriores a `{m.get('minSupportedVersion', m['latestVersion'])}` requieren actualizar."]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY

FILES_ARGS=()
for key in "${!FILES[@]}"; do FILES_ARGS+=("${FILES[$key]}"); done
FILES_ARGS+=("$MANIFEST")

# El tag tiene que señalar EXACTAMENTE el commit del que salieron estos APKs.
# Se crea/fuerza y se empuja ANTES de la Release: si se deja a `gh release
# create`, GitHub crea el tag desde la punta del branch por defecto del remoto,
# que va por detrás cuando el push va después del publish (en v3.3.13 el tag
# quedó apuntando al commit de v3.3.12). Empujar el par <commit,tag> sube
# también el commit si todavía no estaba en el remoto.
COMMIT_REF="$(git -C "$PROY" rev-parse HEAD)"
echo "Commit de origen del build: $COMMIT_REF"
git -C "$PROY" tag -f -a "$TAG" "$COMMIT_REF" -m "Inutix TV $TAG" >/dev/null
if git -C "$PROY" push -f origin "$COMMIT_REF:refs/tags/$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG -> $COMMIT_REF"
else
  echo "AVISO: no se pudo crear/mover el tag $TAG en el remoto (sin credenciales de push?). La Release usará la punta por defecto de la rama."
fi

if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "${FILES_ARGS[@]}" --clobber --repo "$RELEASE_REPO"
else
  gh release create "$TAG" "${FILES_ARGS[@]}" --repo "$RELEASE_REPO" \
    --target "$COMMIT_REF" --title "Inutix TV $TAG" --notes-file "$NOTES_MD"
fi
echo "OK GitHub Release: https://github.com/$RELEASE_REPO/releases/tag/$TAG"

# --- Sincronizar Firestore app_config/tv_release ---
TOKEN="${FIREBASE_ACCESS_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TOKEN="$(python3 -c "import sys; sys.path.append('$PROY/tool'); import firebase_admin as fa; print(fa.get_auth_token())" 2>/dev/null || true)"
fi
if [ -z "$TOKEN" ] && [ -f "$HOME/.config/configstore/firebase-tools.json" ]; then
  TOKEN="$(python3 - <<'PY'
import json, pathlib, time
p = pathlib.Path.home() / ".config" / "configstore" / "firebase-tools.json"
try:
    data = json.loads(p.read_text())
    tok = data.get("tokens") or {}
    access = tok.get("access_token", "")
    exp = float(tok.get("expires_at", 0) or 0) / 1000.0
    if access and (exp == 0 or exp > time.time() + 60):
        print(access)
    else:
        print("")
except Exception:
    print("")
PY
)"
fi

FIRESTORE_URL="https://firestore.googleapis.com/v1/projects/$PROJECT_ID/databases/(default)/documents/app_config/tv_release"
BODY_FILE="$MANIFEST_DIR/firestore_body.json"
MANIFEST="$MANIFEST" python3 - <<'PY' > "$BODY_FILE"
import json, os
r = json.loads(open(os.environ["MANIFEST"], encoding="utf-8").read())
fields = {
    "latestVersion": {"stringValue": r["latestVersion"]},
    "minSupportedVersion": {"stringValue": r.get("minSupportedVersion", r["latestVersion"])},
    "apkDownloadUrl": {"stringValue": r.get("apkDownloadUrl", "")},
    "mandatory": {"booleanValue": bool(r.get("mandatory", False))},
    "publishedAt": {"timestampValue": r["publishedAt"].replace("+00:00", "Z")},
    "releaseNotes": {"arrayValue": {"values": [{"stringValue": n} for n in r.get("releaseNotes", [])]}},
    "androidDownloads": {
        "mapValue": {"fields": {k: {"stringValue": v} for k, v in r.get("androidDownloads", {}).items()}}
    },
}
print(json.dumps({"fields": fields}, ensure_ascii=False))
PY

if [ -n "$TOKEN" ]; then
  echo "Actualizando Firestore app_config/tv_release ..."
  if curl -sf -X PATCH "$FIRESTORE_URL" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      --data @"$BODY_FILE" > /dev/null; then
    echo "OK Firestore app_config/tv_release actualizado!"
  else
    echo "AVISO: no se pudo actualizar Firestore con el token actual." >&2
  fi
else
  echo "AVISO: sin FIREBASE_ACCESS_TOKEN válido; se publicó en GitHub Releases (la app igual lo detecta vía release.json)." >&2
fi

# --- Sincronizar nodo autoritativo api.inutix.com (S7 SQLite) y purgar backup.inutix.com ---
INUTIX_ADMIN_SECRET="${RELAY_ADMIN_SECRET:-}"
INUTIX_SECRET_FILE="${RELAY_ADMIN_SECRET_FILE:-$HOME/.config/inutil_relay/admin_secret.txt}"
if [ -z "$INUTIX_ADMIN_SECRET" ] && [ -f "$INUTIX_SECRET_FILE" ]; then
  INUTIX_ADMIN_SECRET="$(tr -d '\r\n' < "$INUTIX_SECRET_FILE")"
fi
if [ -n "$INUTIX_ADMIN_SECRET" ]; then
  INUTIX_PRIMARY="${INUTIX_API_BASE:-https://api.inutix.com}"
  INUTIX_RELEASE_URL="${INUTIX_PRIMARY%/}/v1/projects/$PROJECT_ID/databases/(default)/documents/app_config/tv_release"
  echo "Actualizando nodo autoritativo $INUTIX_PRIMARY app_config/tv_release ..."
  if curl -sf -X PATCH "$INUTIX_RELEASE_URL" \
      -A "Mozilla/5.0 (compatible; InutilReleasePipeline/1.0)" \
      -H "X-Admin-Secret: $INUTIX_ADMIN_SECRET" \
      -H "Content-Type: application/json" \
      --data @"$BODY_FILE" > /dev/null; then
    echo "OK $INUTIX_PRIMARY app_config/tv_release actualizado!"
  else
    echo "AVISO: no se pudo actualizar $INUTIX_PRIMARY app_config/tv_release." >&2
  fi

  INUTIX_BACKUP="${INUTIX_BACKUP_BASE:-https://backup.inutix.com}"
  echo "Invalidando caché en $INUTIX_BACKUP (app_config/tv_release) ..."
  if curl -sf -X POST "${INUTIX_BACKUP%/}/admin/invalidate" \
      -A "Mozilla/5.0 (compatible; InutilReleasePipeline/1.0)" \
      -H "X-Admin-Secret: $INUTIX_ADMIN_SECRET" \
      -H "Content-Type: application/json" \
      -d '{"path":"app_config/tv_release"}' > /dev/null; then
    echo "OK $INUTIX_BACKUP invalidado!"
  else
    echo "AVISO: no se pudo invalidar $INUTIX_BACKUP." >&2
  fi
else
  echo "AVISO: sin RELAY_ADMIN_SECRET ($INUTIX_SECRET_FILE); omitida sincronización con api.inutix.com y backup.inutix.com." >&2
fi

echo "Publicado Inutix TV $TAG"
