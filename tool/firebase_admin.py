#!/usr/bin/env python3
"""
InútilTV / Inútil Music — Suite Profesional de Administración Firebase
======================================================================
Permite a César gestionar usuarios, licencias, vigencias y equipos
de forma profesional tanto por consola (CLI) como mediante un Panel Web local.

Uso CLI:
    python3 tool/firebase_admin.py list
    python3 tool/firebase_admin.py aprobar <email_o_uid> [--dias 30 | --permanente]
    python3 tool/firebase_admin.py renovar <email_o_uid> --dias 30
    python3 tool/firebase_admin.py permanente <email_o_uid>
    python3 tool/firebase_admin.py liberar <email_o_uid>
    python3 tool/firebase_admin.py rol <email_o_uid> <admin|user>
    python3 tool/firebase_admin.py suspender <email_o_uid>
    python3 tool/firebase_admin.py activar <email_o_uid>
    python3 tool/firebase_admin.py crear <email> <password> [--nombre "Juan"] [--dias 30]
    python3 tool/firebase_admin.py eliminar <email_o_uid>

Uso Panel Web Profesional:
    python3 tool/firebase_admin.py web [--port 8088]
    -> Abre http://localhost:8088 con interfaz Liquid Glass e inicio de
       sesión con Google (solo cuentas admin). Tema igual a las apps.
"""
import argparse
import base64
import datetime
import hashlib
import http.server
import json
import os
import secrets
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

PROJECT_ID = "inutil-music-app"
API_KEY = "AIzaSyBLg1eN_N7Djc8X1Kri5MQFS-bnS2vVv-c"
# FB_API_BASE permite enrutar las lecturas/escrituras de Firestore del panel por el
# relay del S7 (cache SQLite en el telefono => cero cuota despues de la primera vez).
# Por defecto va directo a Google. Auth (AUTH_URL) NUNCA pasa por el relay.
FIRESTORE_URL = (f"{os.environ.get('FB_API_BASE', 'https://firestore.googleapis.com')}"
                 f"/v1/projects/{PROJECT_ID}/databases/(default)/documents")
AUTH_URL = "https://identitytoolkit.googleapis.com/v1"
CONFIGSTORE_PATH = Path("/home/cesar/.config/configstore/firebase-tools.json")
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
# Cliente OAuth público del propio firebase-tools (fuente: firebase-tools/lib/api.js).
# Es el mismo par cliente_id/secret con el que el CLI refresca su token.
CLI_OAUTH_CLIENT_ID = "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com"
CLI_OAUTH_CLIENT_SECRET = "j9iVZfS8kkCEFUPaAeJV0sAi"

# --- Invalidacion de las capas de cache (relay S7 + Worker cloud) -----------
# El panel y el CLI escriben DIRECTO a Google: `FB_API_BASE` no viene por defecto,
# asi que `FIRESTORE_URL` es `firestore.googleapis.com` y AUTH_URL nunca pasa por
# relay. Consecuencia medida: un cambio de licencia/estado hecho desde el panel
# queda INVISIBLE para las apps hasta que caduca el cache del tier por el que
# leen (hot_ttl/cache permanente en el S7, `CACHE_TTL=60` en el Worker).
# `relay_invalidate()` avisa a las dos capas despues de CADA escritura:
# `POST /admin/invalidate {"path": ...}` + `X-Admin-Secret`, el MISMO contrato y
# el MISMO secreto en las dos capas. Verificado en vivo el 2026-11-20 con la
# llave del S7 (`/data/adb/relay/secrets/admin_secret.txt`, copiada a
# `~/.config/inutil_relay/admin_secret.txt` chmod 600): `{"ok":true,
# "docs_deleted_purged":0}` en `users/__probe_inexistent__` tanto en
# `http://192.168.100.27:8080/admin/invalidate` como en
# `https://inutil-cloud-relay.scada-xiaomi-server.workers.dev/admin/invalidate`,
# y `401` con la llave equivocada.
# Todo error se traga y se loguea a stderr: purgar es una optimizacion y nunca
# debe tumbar ni interrumpir una escritura que ya se pago en Google.
# Variables de entorno:
#   RELAY_INVALIDATE=0             no avisar a ninguna capa
#   RELAY_INVALIDATE_BASES=a,b     cambiar las capas avisadas
#   RELAY_ADMIN_SECRET / _FILE     cambiar la llave
RELAY_INVALIDATE_ENABLED = os.environ.get("RELAY_INVALIDATE", "1").strip() != "0"
RELAY_INVALIDATE_BASES = [b.strip().rstrip("/")
                          for b in os.environ.get("RELAY_INVALIDATE_BASES", "").split(",")
                          if b.strip()]
if not RELAY_INVALIDATE_BASES:
    # Las dos capas tal como estan desplegadas hoy: tier 1 = relay del S7 (LAN),
    # tier 2 = Worker cloud. Que una de las dos no responda es NORMAL (el PC
    # puede estar fuera de la LAN) y no es un error: se loguea y listo.
    RELAY_INVALIDATE_BASES = ["https://api.inutix.com",
                              "http://192.168.100.27:8080",
                              "https://backup.inutix.com"]
ADMIN_SECRET_FILE_DEFAULT = "/home/cesar/.config/inutil_relay/admin_secret.txt"
RELAY_ADMIN_SECRET = os.environ.get("RELAY_ADMIN_SECRET", "").strip()
if not RELAY_ADMIN_SECRET:
    _secret_path = os.environ.get("RELAY_ADMIN_SECRET_FILE",
                                 ADMIN_SECRET_FILE_DEFAULT).strip()
    try:
        if _secret_path and os.path.exists(_secret_path):
            RELAY_ADMIN_SECRET = open(_secret_path, encoding="utf-8").read().strip()
    except Exception:
        pass

def fs_doc_path(url):
    """`<FIRESTORE_URL>/users/<uid>?updateMask...` -> `users/<uid>`; None si la
    URL no es un documento Firestore. Las tablas `docs` de las dos capas guardan
    el path RELATIVO (`users/<uid>`), no el path de Google completo, por eso se
    recorta el prefijo: `relay.py` lo hace con su `BASE_PREFIX` (`relay.py:122`)
    y el Worker con el suyo.
    Un path de Firestore alterna coleccion/documento, asi que un numero IMPAR
    de renglones es una coleccion (`users`, `users/uid/tv_remote`) y no tiene
    sentido purgarla como documento: se devuelve None y quien quiera purgar
    una coleccion entera usa la clave `collection` del propio endpoint."""
    if not url.startswith(FIRESTORE_URL):
        return None
    tail = url[len(FIRESTORE_URL):].split("?")[0].strip("/").rstrip("/")
    segs = [s for s in tail.split("/") if s]
    if not segs or len(segs) % 2:
        return None
    return "/".join(segs)

def relay_invalidate(path, skip=None, log=True):
    """Purga `path` del cache de cada capa de `RELAY_INVALIDATE_BASES`.
    `skip` = bases por las que la escritura YA paso (si el panel escribio con
    `FB_API_BASE` apuntando a una capa, purgar esa misma capa le costaria una
    lectura pagada de mas). Devuelve {base: codigo o error} y NUNCA lanza: quien
    llama ya pago su escritura en Google y no puede revertirla."""
    if not RELAY_INVALIDATE_ENABLED or not path:
        return {}
    skip = skip or set()
    body = json.dumps({"path": path}).encode("utf-8")
    out = {}
    for base in RELAY_INVALIDATE_BASES:
        if base in skip:
            continue
        try:
            req = urllib.request.Request(
                f"{base}/admin/invalidate", data=body, method="POST",
                headers={"Content-Type": "application/json",
                         "X-Admin-Secret": RELAY_ADMIN_SECRET,
                         # Medido 2026-11-20 14:30: con el User-Agent que pone
                         # urllib (`Python-urllib/3.x`) Cloudflare responde
                         # `error code: 1010` + 403 (regla de firma de
                         # navegador), y el aviso se pierde. Con cualquier otro
                         # UA — incluso `python-requests/2.32.3` — responde
                         # `200 {"ok":true,...}`. Se manda un UA descriptivo
                         # propio para no depender de ese detalle.
                         "User-Agent": "Mozilla/5.0 (compatible; InutilAdminPanel/1.0; /admin/invalidate)"})
            with urllib.request.urlopen(req, timeout=4) as response:
                out[base] = response.status
        except urllib.error.HTTPError as e:
            out[base] = f"HTTP {e.code}"
        except Exception as e:
            out[base] = str(e)
        if log and out[base] not in (200, 204):
            # 401 = falta la llave (o es otra); lo demas es red. Ninguno debe
            # detener el panel, pero ninguno debe pasar desapercibido.
            print(f"[relay-invalidate] {base} -> {out[base]}", file=sys.stderr)
    return out

def load_configstore():
    if CONFIGSTORE_PATH.exists():
        try:
            with open(CONFIGSTORE_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def _refresh_oauth_token(refresh_token):
    """Refresca el access_token con el refresh_token del CLI (flujo OAuth estándar)."""
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLI_OAUTH_CLIENT_ID,
        "client_secret": CLI_OAUTH_CLIENT_SECRET,
    }).encode()
    req = urllib.request.Request(
        TOKEN_ENDPOINT, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.loads(response.read().decode("utf-8")).get("access_token")
    except Exception:
        return None

# Cache de proceso: token recién refrescado (no se toca el configstore del CLI).
_refreshed_token_cache = {"token": None}

def get_auth_token(force_refresh=False):
    data = load_configstore()
    tokens = data.get("tokens", {}) or {}
    if not isinstance(tokens, dict):
        tokens = {}
    # El CLI guarda el token plano; se acepta también el formato agrupado por origen.
    grouped = tokens.get("firebase") if isinstance(tokens.get("firebase"), dict) else None
    access_token = (grouped or tokens).get("access_token")
    refresh_token = (grouped or tokens).get("refresh_token")
    expires_at = (grouped or tokens).get("expires_at")

    def _expired(value):
        try:
            # firebase-tools guarda expires_at en epoch de milisegundos.
            return float(value) / 1000.0 <= datetime.datetime.now().timestamp() + 60
        except (TypeError, ValueError):
            return False

    if not force_refresh and access_token and not _expired(expires_at):
        return access_token
    if force_refresh and _refreshed_token_cache["token"]:
        return _refreshed_token_cache["token"]
    if refresh_token:
        fresh = _refresh_oauth_token(refresh_token)
        if fresh:
            _refreshed_token_cache["token"] = fresh
            return fresh
    return access_token

def make_request(url, method="GET", data=None, token=None):
    explicit_token = token
    token = explicit_token or get_auth_token()
    res = _do_request(url, method=method, data=data, token=token)
    # Token revocado/expirado en el servidor: un reintento con token fresco.
    if isinstance(res, dict) and res.get("code") == 401 and not explicit_token:
        fresh = get_auth_token(force_refresh=True)
        if fresh and fresh != token:
            res = _do_request(url, method=method, data=data, token=fresh)
    # Escritura pagada -> avisar a las capas de cache. Antes de esto el panel
    # escribia y las apps seguian viendo el documento VIEJO hasta que caducaba
    # el TTL del tier por donde leian (S7: cache permanente salvo app_config;
    # Worker: 60 s). Se avisa solo si la escritura salio bien: un PATCH que
    # Google rechazo no dejo nada que purgar.
    if method in ("PATCH", "POST", "DELETE") and not (isinstance(res, dict)
                                                       and "error" in res):
        doc = fs_doc_path(url)
        if doc:
            # Si la escritura ya paso por una de las capas (`FB_API_BASE`
            # apuntando a ella), esa capa ya actualizo su propio cache: no hay
            # que purgarla, porque purgarla le costaria una lectura pagada.
            relay_invalidate(doc, skip={b for b in RELAY_INVALIDATE_BASES
                                        if FIRESTORE_URL.startswith(b)})
    return res

def _do_request(url, method="GET", data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=12) as response:
            res_body = response.read().decode("utf-8")
            return json.loads(res_body) if res_body else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        try:
            err_json = json.loads(err_body)
            msg = err_json.get("error", {}).get("message", err_body)
            return {"error": msg, "code": e.code}
        except Exception:
            return {"error": err_body, "code": e.code}
    except Exception as e:
        return {"error": str(e), "code": 500}

def decode_firestore_fields(fields):
    out = {}
    for k, v in fields.items():
        if "stringValue" in v:
            out[k] = v["stringValue"]
        elif "integerValue" in v:
            out[k] = int(v["integerValue"])
        elif "doubleValue" in v:
            out[k] = float(v["doubleValue"])
        elif "booleanValue" in v:
            out[k] = v["booleanValue"]
        elif "timestampValue" in v:
            out[k] = v["timestampValue"]
        elif "nullValue" in v:
            out[k] = None
        elif "mapValue" in v:
            out[k] = decode_firestore_fields(v.get("mapValue", {}).get("fields", {}))
        elif "arrayValue" in v:
            vals = v.get("arrayValue", {}).get("values", [])
            out[k] = [decode_firestore_fields({"x": item}).get("x") for item in vals]
        else:
            out[k] = list(v.values())[0] if v else None
    return out

def encode_firestore_fields(data):
    fields = {}
    for k, v in data.items():
        if isinstance(v, bool):
            fields[k] = {"booleanValue": v}
        elif isinstance(v, int):
            fields[k] = {"integerValue": str(v)}
        elif isinstance(v, float):
            fields[k] = {"doubleValue": v}
        elif isinstance(v, str):
            fields[k] = {"stringValue": v}
        elif isinstance(v, datetime.datetime):
            fields[k] = {"timestampValue": v.strftime("%Y-%m-%dT%H:%M:%SZ")}
        elif v is None:
            fields[k] = {"nullValue": None}
        elif isinstance(v, dict):
            fields[k] = {"mapValue": {"fields": encode_firestore_fields(v)}}
        elif isinstance(v, list):
            fields[k] = {
                "arrayValue": {
                    "values": [encode_firestore_fields({"x": x})["x"] for x in v]
                }
            }
    return fields

def get_auth_users(token=None):
    url = f"https://identitytoolkit.googleapis.com/v1/projects/{PROJECT_ID}/accounts:batchGet?maxResults=300"
    res = make_request(url, token=token)
    if "error" in res:
        return []
    raw_users = res.get("users", [])
    users = []
    for u in raw_users:
        uid = u.get("localId")
        email = u.get("email", "")
        custom = {}
        if u.get("customAttributes"):
            try:
                custom = json.loads(u.get("customAttributes"))
            except Exception:
                pass
        created_epoch = int(u.get("createdAt", "0")) / 1000.0 if u.get("createdAt") else 0
        last_epoch = int(u.get("lastLoginAt", "0")) / 1000.0 if u.get("lastLoginAt") else 0
        created_str = datetime.datetime.fromtimestamp(created_epoch, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M") if created_epoch else "-"
        last_str = datetime.datetime.fromtimestamp(last_epoch, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M") if last_epoch else "-"

        is_founder = email.lower() in ("cesarmaster133@gmail.com", "humbertoglez96@gmail.com", "cesar@inutilmusic.com")
        role = custom.get("role") or ("admin" if is_founder else "user")
        status = "blocked" if u.get("disabled") else (custom.get("status") or ("active" if is_founder else "pending"))
        exp = custom.get("accountExpiresAt") or ("2099-12-31T23:59:59Z" if is_founder else None)

        users.append({
            "uid": uid,
            "email": email,
            "displayName": u.get("displayName") or email.split("@")[0],
            "role": role,
            "status": status,
            "isActive": not u.get("disabled", False) and status == "active",
            "accountExpiresAt": exp,
            "disabled": u.get("disabled", False),
            "createdAt": created_str,
            "lastLoginAt": last_str,
            "_source": "auth",
        })
    return users

def get_all_users(token=None, with_meta=False):
    # Intenta Firestore primero
    url = f"{FIRESTORE_URL}/users?pageSize=300"
    res = make_request(url, token=token)
    firestore_ok = "error" not in res
    users = []
    if firestore_ok:
        docs = res.get("documents", [])
        for d in docs:
            uid = d.get("name", "").split("/")[-1]
            fields = decode_firestore_fields(d.get("fields", {}))
            fields["uid"] = fields.get("uid") or uid
            fields["_source"] = "firestore"
            users.append(fields)

    # Combina con Firebase Auth como fuente confiable
    auth_users = get_auth_users(token=token)
    if not users:
        return (auth_users, firestore_ok) if with_meta else auth_users

    by_uid = {u["uid"]: u for u in users}
    for au in auth_users:
        if au["uid"] not in by_uid:
            users.append(au)
        else:
            by_uid[au["uid"]]["disabled"] = au.get("disabled", False)
            by_uid[au["uid"]]["lastLoginAt"] = au.get("lastLoginAt", "-")
    return (users, firestore_ok) if with_meta else users

def find_user(identifier, token=None):
    users = get_all_users(token=token)
    ident = identifier.strip().lower()
    for u in users:
        if u.get("uid", "").lower() == ident or u.get("email", "").lower() == ident:
            return u
    return None

def update_user_fields(uid, updates, token=None):
    # 1. Actualizar Firebase Auth (Claims / Disabled)
    auth_data = {"localId": uid}
    auth_mask = []
    if "isActive" in updates:
        auth_data["disableUser"] = not updates["isActive"]
        # Sin fieldMask, un disableUser=false se ignora (valor por defecto del proto).
        auth_mask.append("disableUser")

    claims = {}
    if "role" in updates:
        claims["role"] = updates["role"]
    if "status" in updates:
        claims["status"] = updates["status"]
    if "accountExpiresAt" in updates:
        claims["accountExpiresAt"] = updates["accountExpiresAt"]
    if claims:
        auth_data["customAttributes"] = json.dumps(claims)
        auth_mask.append("customAttributes")
    if auth_mask:
        auth_data["fieldMask"] = auth_mask

    auth_url = f"https://identitytoolkit.googleapis.com/v1/projects/{PROJECT_ID}/accounts:update"
    auth_res = make_request(auth_url, method="POST", data=auth_data, token=token)
    if "error" in auth_res:
        return auth_res

    # 2. Actualizar Firestore (Best effort si hay cuota)
    encoded = encode_firestore_fields(updates)
    mask_params = "&".join([f"updateMask.fieldPaths={k}" for k in updates.keys()])
    fs_url = f"{FIRESTORE_URL}/users/{uid}?{mask_params}"
    fs_res = make_request(fs_url, method="PATCH", data={"fields": encoded}, token=token)

    if "error" not in auth_res:
        return {"ok": True, "auth": auth_res, "firestore": fs_res}
    return fs_res

def format_date_str(ts_str):
    if not ts_str:
        return "Sin fecha"
    try:
        dt = datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        if dt.year >= 2090:
            return "💎 PERMANENTE"
        now = datetime.datetime.now(datetime.timezone.utc)
        diff = (dt - now).days
        date_fmt = dt.strftime("%d/%m/%Y")
        if diff < 0:
            return f"❌ Vencido ({date_fmt})"
        return f"✅ {diff}d ({date_fmt})"
    except Exception:
        return ts_str[:10]

# ─────────────────────────────────────────────────────────────────────────────
# COMANDOS CLI
# ─────────────────────────────────────────────────────────────────────────────

def cmd_list(args):
    users = get_all_users()
    if not users:
        print("No se encontraron usuarios o la cuota de lectura se encuentra agotada.")
        return
    print(f"\n{'='*95}")
    print(f"  USUARIOS Y LICENCIAS EN FIREBASE ({len(users)} cuentas registradas)")
    print(f"{'='*95}")
    print(f"{'EMAIL':<30} {'ROL':<8} {'ESTADO':<10} {'VIGENCIA':<20} {'EQUIPOS (TV/MÓVIL)':<22}")
    print("-" * 95)
    for u in sorted(users, key=lambda x: x.get("email", "")):
        email = u.get("email", "sin_correo")[:29]
        role = u.get("role", "user")
        status = u.get("status", "active")
        exp = format_date_str(u.get("accountExpiresAt", ""))
        tv = u.get("pairedTvDeviceId") or u.get("currentSmartTvDeviceId") or ""
        phone = u.get("currentPhoneDeviceId") or u.get("currentTvDeviceId") or ""
        devices = []
        if tv: devices.append("TV: " + tv[:6])
        if phone: devices.append("Cel: " + phone[:6])
        dev_str = " · ".join(devices) if devices else "Ninguno"
        print(f"{email:<30} {role:<8} {status:<10} {exp:<20} {dev_str:<22}")
    print("-" * 95 + "\n")

def cmd_aprobar(args):
    user = find_user(args.usuario)
    if not user:
        print(f"❌ Usuario no encontrado: {args.usuario}")
        return
    uid = user["uid"]
    email = user.get("email", uid)
    if args.permanente:
        exp = "2099-12-31T23:59:59Z"
        days = 36500
    else:
        days = args.dias or 30
        now = datetime.datetime.now(datetime.timezone.utc)
        exp = (now + datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    updates = {
        "status": "active",
        "isActive": True,
        "accountExpiresAt": exp,
        "accountDurationDays": days,
        "lastValidatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    res = update_user_fields(uid, updates)
    if "error" in res:
        print(f"❌ Error al aprobar: {res['error']}")
    else:
        print(f"✅ ¡Usuario {email} APROBADO con éxito! Vigencia: {'💎 Permanente' if args.permanente else f'+{days} días'} ({exp[:10]}).")

def cmd_liberar(args):
    user = find_user(args.usuario)
    if not user:
        print(f"❌ Usuario no encontrado: {args.usuario}")
        return
    uid = user["uid"]
    email = user.get("email", uid)
    updates = {
        "currentPhoneDeviceId": "",
        "currentTvDeviceId": "",
        "currentSmartTvDeviceId": "",
        "pairedTvDeviceId": "",
        "phoneSwitchCount": 0,
    }
    res = update_user_fields(uid, updates)
    if "error" in res:
        print(f"❌ Error al liberar: {res['error']}")
    else:
        print(f"✅ Dispositivos de {email} LIBERADOS. Puede iniciar sesión en su nueva TV o celular.")

def cmd_rol(args):
    user = find_user(args.usuario)
    if not user:
        print(f"❌ Usuario no encontrado: {args.usuario}")
        return
    role = args.rol.lower()
    if role not in ["admin", "user"]:
        print("❌ Rol inválido. Use 'admin' o 'user'.")
        return
    res = update_user_fields(user["uid"], {"role": role})
    if "error" in res:
        print(f"❌ Error: {res['error']}")
    else:
        print(f"✅ Rol de {user.get('email')} actualizado a '{role}'.")

def _set_vigencia(usuario, days=None, permanente=False, label=""):
    user = find_user(usuario)
    if not user:
        print(f"❌ Usuario no encontrado: {usuario}")
        return
    now = datetime.datetime.now(datetime.timezone.utc)
    if permanente:
        exp, days = "2099-12-31T23:59:59Z", 36500
    else:
        days = days or 30
        exp = (now + datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    res = update_user_fields(user["uid"], {
        "status": "active",
        "isActive": True,
        "accountExpiresAt": exp,
        "accountDurationDays": days,
        "lastValidatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    if isinstance(res, dict) and "error" in res:
        print(f"❌ Error: {res['error']}")
    else:
        print(f"✅ {label} {user.get('email')} → {'💎 Permanente' if permanente else f'+{days} días'} ({exp[:10]}).")

def cmd_renovar(args):
    _set_vigencia(args.usuario, days=args.dias, label="Renovada vigencia de")

def cmd_permanente(args):
    _set_vigencia(args.usuario, permanente=True, label="Licencia PERMANENTE para")

def _set_status(usuario, status, is_active, label):
    user = find_user(usuario)
    if not user:
        print(f"❌ Usuario no encontrado: {usuario}")
        return
    res = update_user_fields(user["uid"], {"status": status, "isActive": is_active})
    if isinstance(res, dict) and "error" in res:
        print(f"❌ Error: {res['error']}")
    else:
        print(f"✅ {label} {user.get('email')}.")

def cmd_suspender(args):
    _set_status(args.usuario, "blocked", False, "Usuario SUSPENDIDO:")

def cmd_activar(args):
    _set_status(args.usuario, "active", True, "Usuario ACTIVADO:")

def cmd_crear(args):
    # batchCreate (uploadAccount): password en Base64, localId generado aquí.
    # OJO: customAttributes en el cuerpo de batchCreate rompe el endpoint (400);
    # se fijan después con accounts:update + fieldMask.
    import secrets
    import string as _string
    new_uid = "".join(secrets.choice(_string.ascii_letters + _string.digits) for _ in range(28))
    user = {"localId": new_uid, "email": args.email,
            "password": base64.b64encode(args.password.encode()).decode()}
    if args.nombre:
        user["displayName"] = args.nombre
    days = args.dias if args.dias is not None else 30
    exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    res = make_request(f"{AUTH_URL}/projects/{PROJECT_ID}/accounts:batchCreate",
                       method="POST", data={"users": [user]})
    if "error" in res or res.get("errors"):
        print(f"❌ Error al crear: {res.get('error') or res.get('errors')}")
        return
    claims = {"role": "user", "status": "active", "accountExpiresAt": exp}
    upd = make_request(f"{AUTH_URL}/projects/{PROJECT_ID}/accounts:update", method="POST",
                       data={"localId": new_uid, "customAttributes": json.dumps(claims),
                             "fieldMask": ["customAttributes"]})
    if "error" in upd:
        print(f"⚠️ Usuario creado (uid {new_uid}) pero los claims NO se guardaron: {upd['error'][:80]}")
        return
    print(f"✅ Usuario creado: {args.email} (uid {new_uid}) vigencia +{days} días ({exp[:10]}).")

def cmd_eliminar(args):
    user = find_user(args.usuario)
    if not user:
        print(f"❌ Usuario no encontrado: {args.usuario}")
        return
    uid = user["uid"]
    # batchDelete exige cuenta deshabilitada antes de borrar.
    dis = make_request(f"{AUTH_URL}/projects/{PROJECT_ID}/accounts:update",
                       method="POST", data={"localId": uid, "disableUser": True})
    if "error" in dis:
        print(f"❌ Error al deshabilitar antes de borrar: {dis['error']}")
        return
    res = make_request(f"{AUTH_URL}/projects/{PROJECT_ID}/accounts:batchDelete",
                       method="POST", data={"localIds": [uid]})
    if "error" in res or res.get("errors"):
        print(f"❌ Error al eliminar de Auth: {res.get('error') or res.get('errors')}")
        return
    fs = make_request(f"{FIRESTORE_URL}/users/{uid}", method="DELETE")
    note = "" if "error" not in fs else f" (Firestore pendiente: {fs['error'][:60]})"
    print(f"✅ Usuario {user.get('email')} ELIMINADO de Auth.{note}")

# ─────────────────────────────────────────────────────────────────────────────
# LOGIN GOOGLE DEL PANEL (mismo cliente OAuth público del firebase-tools)
# ─────────────────────────────────────────────────────────────────────────────
GOOGLE_CLIENT_ID = "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET = "j9iVZfS8kkCEFUPaAeJV0sAi"
ADMIN_EMAILS = {"cesar@inutilmusic.com", "humbertoglez96@gmail.com", "cesarmaster133@gmail.com"}
OAUTH_SCOPE = "openid email https://www.googleapis.com/auth/firebase"
SESSION_COOKIE = "agadmin"
# estado PKCE {state: verifier} y sesiones {cookie: {"email":..., "source":...}}
_oauth_states = {}
_sessions = {}

def build_login_url(port):
    verifier = secrets.token_urlsafe(64)
    state = secrets.token_urlsafe(16)
    _oauth_states[state] = verifier
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    q = urllib.parse.urlencode({
        "client_id": GOOGLE_CLIENT_ID,
        "redirect_uri": f"http://localhost:{port}/oauth/callback",
        "response_type": "code",
        "scope": OAUTH_SCOPE,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })
    return f"https://accounts.google.com/o/oauth2/v2/auth?{q}"

def exchange_code(code, verifier, port):
    body = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "client_id": GOOGLE_CLIENT_ID,
        "client_secret": GOOGLE_CLIENT_SECRET,
        "code_verifier": verifier,
        "redirect_uri": f"http://localhost:{port}/oauth/callback",
    }).encode()
    req = urllib.request.Request(TOKEN_ENDPOINT, data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))

def email_from_id_token(id_token):
    try:
        payload = id_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("email", "").lower()
    except Exception:
        return ""

def configstore_email():
    data = load_configstore().get("user", {}) if CONFIGSTORE_PATH.exists() else {}
    return (data.get("email") or "").lower()

def get_inactivity_policy(token=None):
    res = make_request(f"{FIRESTORE_URL}/app_config/inactivity_policy", token=token)
    if "error" in res:
        return {"enabled": True, "days": 15, "source": "por defecto (lectura no disponible)"}
    fields = decode_firestore_fields(res.get("fields", {}))
    days = fields.get("days")
    return {"enabled": bool(fields.get("enabled", True)),
            "days": int(days) if isinstance(days, (int, float)) else 15,
            "source": "app_config/inactivity_policy"}

def activity_status(last_active_iso, policy_days, enabled=True):
    """Semáforo de la regla de 15 días por usuario."""
    if not last_active_iso:
        return {"days": None, "light": "none", "label": "sin datos"}
    try:
        dt = datetime.datetime.fromisoformat(str(last_active_iso).replace("Z", "+00:00"))
        days = (datetime.datetime.now(datetime.timezone.utc) - dt).days
    except Exception:
        return {"days": None, "light": "none", "label": "sin datos"}
    if not enabled:
        return {"days": days, "light": "ok", "label": f"{days}d (pausa desactivada)"}
    if days >= policy_days:
        return {"days": days, "light": "over", "label": f"⚠️ {days}d ≥ {policy_days}d"}
    if days >= policy_days - 5:
        return {"days": days, "light": "warn", "label": f"{days}d (al límite)"}
    return {"days": days, "light": "ok", "label": f"{days}d OK"}

# ─────────────────────────────────────────────────────────────────────────────
# PANEL WEB LOCAL MODERNO
# ─────────────────────────────────────────────────────────────────────────────

CSS = """
  :root {
    --bg: #090a0f; --surface: rgba(20, 23, 34, 0.72); --solid: #141722;
    --border: #232842; --accent: #18C75A; --amber: #E8B949; --danger: #FF4757;
    --text: #F5F7F5; --sub: #8E95A5; --glass: rgba(255,255,255,0.04);
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: radial-gradient(1200px 600px at 80% -10%, #101a26 0%, var(--bg) 55%) fixed, var(--bg);
         color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; padding: 26px; }
  .glass { background: var(--surface); backdrop-filter: blur(14px); border: 1px solid var(--border); border-radius: 16px; }
  .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 22px; padding: 16px 20px; }
  .logo { font-size: 21px; font-weight: 800; display: flex; align-items: center; gap: 9px; }
  .logo b { color: var(--accent); }
  .session { font-size: 13px; color: var(--sub); display: flex; align-items: center; gap: 12px; }
  .banner { margin: 0 0 18px; padding: 12px 16px; border-radius: 12px; font-size: 13.5px;
            background: rgba(232,185,73,0.10); border: 1px solid rgba(232,185,73,0.35); color: #f2d491; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 14px; margin-bottom: 20px; }
  .stat-card { padding: 16px 18px; }
  .stat-title { font-size: 11px; color: var(--sub); text-transform: uppercase; letter-spacing: .6px; }
  .stat-val { font-size: 27px; font-weight: 800; margin-top: 6px; }
  .toolbar { display: flex; gap: 10px; margin-bottom: 18px; flex-wrap: wrap; align-items: center; }
  .search { flex: 1; min-width: 240px; background: var(--solid); border: 1px solid var(--border); padding: 10px 14px; border-radius: 10px; color: #fff; font-size: 14px; }
  .btn { background: var(--solid); border: 1px solid var(--border); color: var(--text); padding: 9px 15px; border-radius: 10px; font-weight: 700; font-size: 13px; cursor: pointer; transition: .2s; text-decoration: none; display: inline-block; }
  .btn:hover { border-color: var(--accent); }
  .btn-primary { background: var(--accent); color: #04140a; border-color: var(--accent); }
  .btn-amber { background: var(--amber); color: #171105; border-color: var(--amber); }
  .btn-danger { color: var(--danger); }
  .btn-sm { padding: 5px 10px; font-size: 11.5px; border-radius: 7px; }
  table { width: 100%; border-collapse: collapse; background: var(--surface); backdrop-filter: blur(14px); border-radius: 16px; overflow: hidden; border: 1px solid var(--border); }
  th, td { padding: 13px 14px; text-align: left; font-size: 13px; border-bottom: 1px solid var(--border); vertical-align: middle; }
  th { background: rgba(10,12,18,0.6); color: var(--sub); font-size: 10.5px; text-transform: uppercase; letter-spacing: .5px; }
  tr:hover { background: var(--glass); }
  .badge { display: inline-block; padding: 4px 9px; border-radius: 999px; font-size: 11px; font-weight: 800; }
  .b-active { background: rgba(24,199,90,0.15); color: var(--accent); }
  .b-pending { background: rgba(232,185,73,0.15); color: var(--amber); }
  .b-blocked { background: rgba(255,71,87,0.15); color: var(--danger); }
  .b-admin { background: rgba(232,185,73,0.25); color: var(--amber); }
  .dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 6px; }
  .d-ok { background: var(--accent); box-shadow: 0 0 8px rgba(24,199,90,.6); }
  .d-warn { background: var(--amber); box-shadow: 0 0 8px rgba(232,185,73,.6); }
  .d-over { background: var(--danger); box-shadow: 0 0 8px rgba(255,71,87,.6); }
  .d-none { background: #3a4059; }
  .actions { display: flex; gap: 6px; flex-wrap: wrap; }
  .small-sub { color: var(--sub); font-size: 11.5px; }
  .footnote { margin-top: 16px; color: var(--sub); font-size: 12.5px; padding: 12px 16px; }
  .login-wrap { min-height: 82vh; display: flex; align-items: center; justify-content: center; }
  .login-card { width: 420px; padding: 44px 38px; text-align: center; }
  .login-logo { font-size: 30px; font-weight: 800; margin-bottom: 8px; }
  .login-logo span { color: var(--accent); }
  .login-sub { color: var(--sub); font-size: 13.5px; margin-bottom: 30px; }
  .gbtn { background: #fff; color: #1f1f1f; border: none; padding: 13px 22px; border-radius: 999px; font-size: 14.5px; font-weight: 700; cursor: pointer; width: 100%; display: flex; align-items: center; justify-content: center; gap: 10px; }
  .gbtn:hover { box-shadow: 0 4px 18px rgba(255,255,255,0.18); }
  .alt { margin-top: 16px; }
  .err { color: var(--danger); font-size: 13px; margin-top: 14px; }
"""

LOGIN_HTML = """<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inútil Admin — Acceso</title><style>__CSS__</style></head>
<body>
  <div class="login-wrap">
    <div class="glass login-card">
      <div class="login-logo">📺 Inútil<span>TV</span> Admin</div>
      <div class="login-sub">Control de licencias, actividad y cuentas.<br>Acceso solo para cuentas de administrador.</div>
      <a href="/oauth/start"><button class="gbtn">
        <svg width="18" height="18" viewBox="0 0 48 48"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3c-1.6 4.7-6.1 8-11.3 8-6.9 0-12.5-5.6-12.5-12.5S17.1 11 24 11c3.1 0 5.9 1.2 8 3l5.7-5.7C33.2 5.1 28.8 3.5 24 3.5 12.7 3.5 3.5 12.7 3.5 24S12.7 44.5 24 44.5 44.5 35.3 44.5 24c0-1.2-.1-2.3-.4-3.5z"/><path fill="#FF3D00" d="M6.3 14.7l6.6 6.5C14.7 16 18.9 13 24 13c3.1 0 5.9 1.2 8 3l5.7-5.7C33.2 6.8 28.8 5.2 24 5.2 17 5.2 10.9 9 8.2 14.2z"/><path fill="#4CAF50" d="M24 46.5c5.1 0 9.9-2 13.4-5.1l-6.2-5.9C29.1 37.3 26.6 38.5 24 38.5c-5.2 0-9.6-3.3-11.3-7.9l-6.5 6.7C9.9 42.9 16.4 46.5 24 46.5z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.9c3.7-3.4 6.1-8.7 6.1-15.5 0-1.2-.1-2.3-.4-3.5z"/></svg>
        Acceder con mi cuenta de Google</button></a>
      <div class="alt"><a class="btn" href="/cli-login">Usar sesión CLI del firebase-tools</a></div>
      <div class="err">__ERR__</div>
    </div>
  </div>
</body></html>"""

DASH_HTML = """<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inútil Admin — Licencias</title><style>__CSS__</style></head>
<body>
  <div class="glass header">
    <div class="logo">📺 Inútil<b>TV</b> · Admin</div>
    <div class="session"><span id="sess"></span><a class="btn btn-sm" href="#" onclick="logout()">Salir</a></div>
  </div>
  <div id="banner"></div>
  <div class="stats" id="statsRow">
    <div class="glass stat-card"><div class="stat-title">Usuarios Totales</div><div class="stat-val" id="totalUsers">-</div></div>
    <div class="glass stat-card"><div class="stat-title">Activos / Vigentes</div><div class="stat-val" style="color:var(--accent)" id="activeUsers">-</div></div>
    <div class="glass stat-card"><div class="stat-title">Pendientes de Aprobación</div><div class="stat-val" style="color:var(--amber)" id="pendingUsers">-</div></div>
    <div class="glass stat-card"><div class="stat-title">Regla de actividad</div><div class="stat-val" id="ruleUsers" style="font-size:17px;line-height:1.5">-</div></div>
  </div>
  <div class="toolbar">
    <input type="text" class="search" id="searchInput" placeholder="Buscar por correo, nombre o UID..." oninput="renderTable()">
    <button class="btn" onclick="filterBy('todos')">Todos</button>
    <button class="btn" onclick="filterBy('pending')">Pendientes</button>
    <button class="btn" onclick="filterBy('active')">Activos</button>
    <button class="btn" onclick="filterBy('admin')">Admins</button>
    <button class="btn btn-primary" onclick="loadUsers()">🔄 Actualizar</button>
  </div>
  <table><thead><tr>
    <th>Usuario / Correo</th><th>Rol</th><th>Estado</th><th>Vigencia</th>
    <th>Actividad (regla <span id="policyDays">15</span>d)</th><th>Plataforma · Versión</th><th>Reactivación</th><th>Dispositivos</th><th>Acciones</th>
  </tr></thead><tbody id="userRows"></tbody></table>
  <div class="glass footnote">📝 Listas de reproducción y tiempo de uso por usuario: la app aún no los reporta a Firestore (se guardan solo en el aparato). En cuanto se instrumente la app, se muestran aquí. Fuente: Firebase Auth (claims) + Firestore cuando la cuota de lectura lo permite.</div>
<script>
let allUsers=[], currentFilter='todos', meta={};
async function loadSession(){ const r=await fetch('/api/session'); const d=await r.json();
  document.getElementById('sess').innerText = d.email ? ('Sesión: '+d.email+' ('+(d.source||'google')+')') : ''; }
async function loadUsers(){
  const res=await fetch('/api/users');
  if(res.status===401){ location.href='/login'; return; }
  const data=await res.json(); allUsers=data.users||[]; meta=data.meta||{};
  if(meta.policy){ document.getElementById('policyDays').innerText=meta.policy.days; }
  const b=document.getElementById('banner');
  if(meta.firestore_ok===false){ b.innerHTML='<div class="banner">📡 Cuota de lecturas de Firestore agotada hoy — mostrando solo Firebase Auth (claims). Actividad y dispositivos volverán tras el reinicio de cuota (medianoche, hora del Pacífico). Política mostrada: '+(meta.policy?meta.policy.days+' días ('+meta.policy.source+')':'15')+'</div>'; }
  else b.innerHTML='';
  renderStats(); renderTable(); }
function renderStats(){
  document.getElementById('totalUsers').innerText=allUsers.length;
  document.getElementById('activeUsers').innerText=allUsers.filter(u=>u.status==='active'||u.role==='admin').length;
  document.getElementById('pendingUsers').innerText=allUsers.filter(u=>u.status==='pending'&&u.role!=='admin').length;
  const c={ok:0,warn:0,over:0}; allUsers.forEach(u=>{const l=(u.activity||{}).light; if(l in c)c[l]++;});
  document.getElementById('ruleUsers').innerHTML='<span style="color:var(--accent)">🟢 '+c.ok+'</span> · <span style="color:var(--amber)">🟡 '+c.warn+'</span> · <span style="color:var(--danger)">🔴 '+c.over+'</span>'; }
function filterBy(f){ currentFilter=f; renderTable(); }
function esc(s){ const d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
function renderTable(){
  const q=document.getElementById('searchInput').value.toLowerCase(); const tbody=document.getElementById('userRows'); tbody.innerHTML='';
  const filtered=allUsers.filter(u=>{
    const t=((u.email||'')+' '+(u.displayName||'')+' '+(u.uid||'')).toLowerCase();
    if(!t.includes(q))return false;
    if(currentFilter==='pending')return u.status==='pending';
    if(currentFilter==='active')return u.status==='active'||u.role==='admin';
    if(currentFilter==='admin')return u.role==='admin';
    return true; });
  filtered.forEach(u=>{
    const tr=document.createElement('tr'); const isAdm=u.role==='admin';
    const stBadge=isAdm?'<span class="badge b-admin">ADMIN</span>':(u.status==='active'?'<span class="badge b-active">ACTIVA</span>':(u.status==='pending'?'<span class="badge b-pending">PENDIENTE</span>':'<span class="badge b-blocked">SUSPENDIDA</span>'));
    const expText=u.accountExpiresAt?(String(u.accountExpiresAt).startsWith('209')?'💎 Permanente':String(u.accountExpiresAt).substring(0,10)):'Sin fecha';
    const a=u.activity||{light:'none',label:'sin datos'};
    const act='<span class="dot d-'+a.light+'"></span>'+esc(a.label);
    const plat=[esc(u.lastActivePlatform||''),esc(u.lastActiveTvVersion||'')].filter(Boolean).join(' · ')||'—';
    const react=u.reactivationRequestedAt?('🔴 pidió reactivación'):'—';
    const devs=[u.currentSmartTvDeviceId?'📺 TV '+esc(String(u.currentSmartTvDeviceId).slice(0,6)):null,
                u.currentTvDeviceId?'📱 Móvil '+esc(String(u.currentTvDeviceId).slice(0,6)):null,
                u.currentPhoneDeviceId?'🎧 Music '+esc(String(u.currentPhoneDeviceId).slice(0,6)):null].filter(Boolean).join(' · ')||'Ninguno';
    tr.innerHTML=
      '<td><strong>'+esc(u.displayName||'Usuario')+'</strong><br><small class="small-sub">'+esc(u.email)+'</small></td>'+
      '<td><span class="badge '+(isAdm?'b-admin':'')+'">'+esc(u.role||'user')+'</span></td>'+
      '<td>'+stBadge+'</td><td>'+esc(expText)+'</td><td>'+act+'</td><td><small class="small-sub">'+plat+'</small></td>'+
      '<td>'+react+'</td><td><small class="small-sub">'+devs+'</small></td>'+
      '<td><div class="actions"></div></td>';
    const box=tr.querySelector('.actions');
    const mk=(label,action,cls)=>{ const b=document.createElement('button'); b.className='btn btn-sm '+(cls||'');
      b.textContent=label; b.onclick=()=>actionUser(u.uid,action); box.appendChild(b); };
    if(u.status==='pending') mk('✔ Aprobar','aprobar','btn-primary');
    mk('+30d','aprobar','btn-primary'); mk('💎 Perm','permanente','btn-amber'); mk('Liberar','liberar');
    mk(u.isActive?'Pausa':'Activar', u.isActive?'suspender':'activar', 'btn-danger');
    tbody.appendChild(tr); }); }
async function actionUser(uid,action){
  const res=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({uid,action,val:30})});
  const data=await res.json(); if(data.ok){ loadUsers(); } else { alert('Error: '+data.error); } }
async function logout(){ await fetch('/logout',{method:'POST'}); location.href='/login'; }
loadSession(); loadUsers();
</script>
</body></html>"""

class AdminHttpHandler(http.server.BaseHTTPRequestHandler):
    def port(self):
        return self.server.server_address[1]

    def session(self):
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            k, _, v = part.strip().partition("=")
            if k == SESSION_COOKIE and v in _sessions:
                return _sessions[v]
        return None

    def session_token(self, sess):
        # Token de la sesión Google; si es sesión CLI, el del configstore (con refresco).
        return (sess or {}).get("token") or get_auth_token()

    def redirect(self, path, cookie_value=None):
        self.send_response(302)
        if cookie_value:
            self.send_header("Set-Cookie", f"{SESSION_COOKIE}={cookie_value}; Path=/; HttpOnly; SameSite=Lax")
        self.send_header("Location", path)
        self.end_headers()

    def send_html(self, html):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        if url.path == "/login":
            err = (q.get("err") or [""])[0]
            self.send_html(LOGIN_HTML.replace("__CSS__", CSS).replace("__ERR__", f'<div class="err">{err}</div>' if err else ""))
            return
        if url.path == "/oauth/start":
            self.redirect(build_login_url(self.port()))
            return
        if url.path == "/oauth/callback":
            code = (q.get("code") or [""])[0]
            state = (q.get("state") or [""])[0]
            verifier = _oauth_states.pop(state, None)
            if not (code and verifier):
                self.redirect("/login?err=estado+OAuth+perdido,+int%C3%A9ntr+de+nuevo")
                return
            try:
                tok = exchange_code(code, verifier, self.port())
            except Exception:
                self.redirect("/login?err=intercambio+de+token+fall%C3%B3")
                return
            email = email_from_id_token(tok.get("id_token", ""))
            if email not in ADMIN_EMAILS:
                self.redirect("/login?err=cuenta+no+autorizada+para+admin")
                return
            key = secrets.token_urlsafe(32)
            _sessions[key] = {"email": email, "source": "google", "token": tok.get("access_token")}
            self.redirect("/", cookie_value=key)
            return
        if url.path == "/cli-login":
            email = configstore_email()
            if email not in ADMIN_EMAILS:
                self.redirect("/login?err=sesi%C3%B3n+CLI+no+es+de+admin")
                return
            key = secrets.token_urlsafe(32)
            _sessions[key] = {"email": email, "source": "cli"}
            self.redirect("/", cookie_value=key)
            return
        sess = self.session()
        if url.path in ("/", "/index.html"):
            if not sess:
                self.redirect("/login")
                return
            self.send_html(DASH_HTML.replace("__CSS__", CSS))
            return
        if url.path == "/logout":
            for part in self.headers.get("Cookie", "").split(";"):
                k, _, v = part.strip().partition("=")
                if k == SESSION_COOKIE:
                    _sessions.pop(v, None)
            self.redirect("/login")
            return
        if url.path == "/api/session":
            self.send_json({"email": sess["email"], "source": sess.get("source")} if sess else {})
            return
        if url.path == "/api/users":
            if not sess:
                self.send_json({"error": "sin sesión", "code": 401}, 401)
                return
            users, fs_ok = get_all_users(token=self.session_token(sess), with_meta=True)
            policy = get_inactivity_policy(token=self.session_token(sess))
            for u in users:
                u["activity"] = activity_status(u.get("lastActiveAt") or u.get("lastLoginAt"),
                                                policy["days"], policy["enabled"])
            self.send_json({"users": users,
                            "meta": {"policy": policy, "firestore_ok": fs_ok,
                                     "session": sess["email"]}})
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        sess = self.session()
        if url.path == "/logout":
            for part in self.headers.get("Cookie", "").split(";"):
                k, _, v = part.strip().partition("=")
                if k == SESSION_COOKIE:
                    _sessions.pop(v, None)
            self.send_json({"ok": True})
            return
        if url.path == "/api/action":
            if not sess:
                self.send_json({"ok": False, "error": "sin sesión"}, 401)
                return
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            uid = payload.get("uid")
            action = payload.get("action")
            val = payload.get("val")
            tok = self.session_token(sess)
            user = find_user(uid, token=tok)
            if not user:
                self.send_json({"ok": False, "error": "Usuario no encontrado"})
                return
            now = datetime.datetime.now(datetime.timezone.utc)
            if action == "aprobar":
                days = int(val or 30)
                exp = (now + datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
                res = update_user_fields(uid, {"status": "active", "isActive": True,
                                               "accountExpiresAt": exp, "accountDurationDays": days}, token=tok)
            elif action == "permanente":
                res = update_user_fields(uid, {"status": "active", "isActive": True,
                                               "accountExpiresAt": "2099-12-31T23:59:59Z",
                                               "accountDurationDays": 36500}, token=tok)
            elif action == "liberar":
                res = update_user_fields(uid, {"currentPhoneDeviceId": "", "currentTvDeviceId": "",
                                               "currentSmartTvDeviceId": "", "pairedTvDeviceId": "",
                                               "phoneSwitchCount": 0}, token=tok)
            elif action == "suspender":
                res = update_user_fields(uid, {"isActive": False, "status": "blocked"}, token=tok)
            elif action == "activar":
                res = update_user_fields(uid, {"isActive": True, "status": "active"}, token=tok)
            else:
                res = {"error": f"Acción desconocida: {action}"}
            self.send_json({"ok": "error" not in res, "res": res})
            return
        self.send_response(404)
        self.end_headers()

    def send_json(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def log_message(self, format, *args):
        # Silenciar logs ruidosos en stdout
        pass

def cmd_web(args):
    port = args.port or 8088
    server = http.server.HTTPServer(("0.0.0.0", port), AdminHttpHandler)
    print(f"\n🚀 Panel Web de Administración Firebase activo en:")
    print(f"   👉 http://localhost:{port}  (login con Google de una cuenta admin)")
    print(f"   👉 http://192.168.100.23:{port} (desde tu red local)")
    print(f"   👉 Cuentas permitidas: {', '.join(sorted(ADMIN_EMAILS))}")
    print(f"Presiona Ctrl+C para detener el servidor.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServidor web detenido.")
def main():
    parser = argparse.ArgumentParser(description="Suite Profesional de Administración Firebase")
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("list", help="Lista usuarios registrados con sus licencias")

    ap_aprobar = subparsers.add_parser("aprobar", help="Aprueba y activa vigencia de un usuario")
    ap_aprobar.add_argument("usuario", help="Email o UID del usuario")
    ap_aprobar.add_argument("--dias", type=int, default=30, help="Días concedidos (default: 30)")
    ap_aprobar.add_argument("--permanente", action="store_true", help="Conceder Licencia Permanente")

    ap_liberar = subparsers.add_parser("liberar", help="Libera dispositivos vinculados")
    ap_liberar.add_argument("usuario", help="Email o UID del usuario")

    ap_rol = subparsers.add_parser("rol", help="Modifica el rol del usuario")
    ap_rol.add_argument("usuario", help="Email o UID del usuario")
    ap_rol.add_argument("rol", choices=["admin", "user"], help="Nuevo rol")

    ap_renovar = subparsers.add_parser("renovar", help="Renueva la vigencia de un usuario")
    ap_renovar.add_argument("usuario", help="Email o UID del usuario")
    ap_renovar.add_argument("--dias", type=int, default=30, help="Días a sumar (default: 30)")

    ap_perm = subparsers.add_parser("permanente", help="Conceder licencia PERMANENTE")
    ap_perm.add_argument("usuario", help="Email o UID del usuario")

    ap_susp = subparsers.add_parser("suspender", help="Suspender usuario")
    ap_susp.add_argument("usuario", help="Email o UID del usuario")

    ap_act = subparsers.add_parser("activar", help="Reactivar usuario")
    ap_act.add_argument("usuario", help="Email o UID del usuario")

    ap_crear = subparsers.add_parser("crear", help="Crear usuario con contraseña")
    ap_crear.add_argument("email", help="Correo del usuario")
    ap_crear.add_argument("password", help="Contraseña (mínimo 6 caracteres)")
    ap_crear.add_argument("--nombre", help="Nombre para mostrar")
    ap_crear.add_argument("--dias", type=int, default=30, help="Días de vigencia (default: 30)")

    ap_elim = subparsers.add_parser("eliminar", help="Eliminar usuario de Auth")
    ap_elim.add_argument("usuario", help="Email o UID del usuario")

    ap_web = subparsers.add_parser("web", help="Inicia el Panel Web de Administración local")
    ap_web.add_argument("--port", type=int, default=8088, help="Puerto HTTP (default: 8088)")

    args = parser.parse_args()

    if args.command == "list" or not args.command:
        cmd_list(args)
    elif args.command == "aprobar":
        cmd_aprobar(args)
    elif args.command == "liberar":
        cmd_liberar(args)
    elif args.command == "rol":
        cmd_rol(args)
    elif args.command == "renovar":
        cmd_renovar(args)
    elif args.command == "permanente":
        cmd_permanente(args)
    elif args.command == "suspender":
        cmd_suspender(args)
    elif args.command == "activar":
        cmd_activar(args)
    elif args.command == "crear":
        cmd_crear(args)
    elif args.command == "eliminar":
        cmd_eliminar(args)
    elif args.command == "web":
        cmd_web(args)

if __name__ == "__main__":
    main()
