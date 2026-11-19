#!/usr/bin/env python3
"""
Envía los APKs de una versión compilada al chat de Telegram de Cesar.
Uso:
  python3 tool/send_release_telegram.py [VERSION] [--chat-id CHAT_ID]
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_CHAT_ID = "1002362473"
ENV_PATH = Path("/home/cesar/.hermes/.env")

def get_bot_token():
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    if token:
        return token
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("TELEGRAM_BOT_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError("No se encontró TELEGRAM_BOT_TOKEN en el entorno ni en /home/cesar/.hermes/.env")

def get_current_version(repo_dir: Path):
    pubspec = repo_dir / "pubspec.yaml"
    if pubspec.exists():
        for line in pubspec.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", line.strip())
            if m:
                return m.group(1)
    return "3.3.5"

def get_notes_for_version(repo_dir: Path, version: str):
    changelog = repo_dir / "CHANGELOG.md"
    if not changelog.exists():
        return "Actualización de InútilTV"
    lines = changelog.read_text(encoding="utf-8", errors="replace").splitlines()
    chosen = None
    for i, line in enumerate(lines):
        if re.match(r"^##\s*\[?" + re.escape(version) + r"\b", line):
            chosen = i
            break
    if chosen is None:
        return "Mejoras de rendimiento y estabilidad."
    notes = []
    for line in lines[chosen + 1:]:
        t = line.strip()
        if t.startswith("## "):
            break
        if not t or t.startswith("#"):
            continue
        t = re.sub(r"^[-*]\s+", "• ", t)
        notes.append(t)
        if len(notes) >= 6:
            break
    return "\n".join(notes) if notes else "Mejoras de rendimiento y estabilidad."

def main():
    parser = argparse.ArgumentParser(description="Envía los APKs de InútilTV a Telegram")
    parser.add_argument("version", nargs="?", default="", help="Versión semver (ej. 3.3.6)")
    parser.add_argument("--chat-id", default=DEFAULT_CHAT_ID, help="ID del chat de Telegram")
    parser.add_argument("--apk-dir", default="", help="Directorio con los APKs")
    args = parser.parse_args()

    repo_dir = Path(__file__).resolve().parent.parent
    version = args.version or get_current_version(repo_dir)
    apk_dir = Path(args.apk_dir) if args.apk_dir else repo_dir / "build/app/outputs/flutter-apk"

    token = get_bot_token()
    notes = get_notes_for_version(repo_dir, version)

    targets = [
        (
            "app-arm64-v8a-release.apk",
            f"InutilTV_v{version}_arm64-v8a.apk",
            f"📺 InútilTV v{version} (arm64-v8a · Móvil / Fire TV / Onn 4K Pro)\n{notes}"
        ),
        (
            "app-armeabi-v7a-release.apk",
            f"InutilTV_v{version}_armeabi-v7a.apk",
            f"📺 InútilTV v{version} (armeabi-v7a · Onn 4K / TV Box 32-bit)\n{notes}"
        ),
    ]

    print(f"=== Enviando APKs de InútilTV v{version} a Telegram (chat {args.chat_id}) ===")
    success_count = 0
    for src_name, upload_name, caption in targets:
        src = apk_dir / src_name
        if not src.exists():
            print(f"⚠️ Archivo no encontrado: {src}", file=sys.stderr)
            continue
        mb = src.stat().st_size / (1024 * 1024)
        print(f"Subiendo {upload_name} ({mb:.1f} MB)...")
        if len(caption) > 1000:
            caption = caption[:995] + "..."
        cmd = [
            "curl", "-sS", "--max-time", "180",
            "-X", "POST",
            f"https://api.telegram.org/bot{token}/sendDocument",
            "-F", f"chat_id={args.chat_id}",
            "-F", f"document=@{src};filename={upload_name}",
            "-F", f"caption={caption}",
        ]
        res_raw = subprocess.check_output(cmd, text=True)
        res = json.loads(res_raw)
        if res.get("ok"):
            msg_id = res.get("result", {}).get("message_id")
            print(f"✅ ENVIADO: {upload_name} -> msg_id={msg_id}")
            success_count += 1
        else:
            print(f"❌ ERROR subiendo {upload_name}: {res}", file=sys.stderr)

    if success_count == 0:
        sys.exit(1)
    print(f"🎉 Envíos completados exitosamente: {success_count} APKs.")

if __name__ == "__main__":
    main()
