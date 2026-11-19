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
    -> Abre http://localhost:8088 con interfaz gráfica moderna Liquid Glass.
"""
import argparse
import datetime
import http.server
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

PROJECT_ID = "inutil-music-app"
API_KEY = "AIzaSyBLg1eN_N7Djc8X1Kri5MQFS-bnS2vVv-c"
FIRESTORE_URL = f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents"
AUTH_URL = "https://identitytoolkit.googleapis.com/v1"
CONFIGSTORE_PATH = Path("/home/cesar/.config/configstore/firebase-tools.json")

def get_auth_token():
    if CONFIGSTORE_PATH.exists():
        try:
            with open(CONFIGSTORE_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            tokens = data.get("tokens", {})
            token = tokens.get("access_token")
            if token:
                return token
        except Exception:
            pass
    return None

def make_request(url, method="GET", data=None, token=None):
    if not token:
        token = get_auth_token()
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

def get_auth_users():
    url = f"https://identitytoolkit.googleapis.com/v1/projects/{PROJECT_ID}/accounts:batchGet?maxResults=300"
    res = make_request(url)
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

def get_all_users():
    # Intenta Firestore primero
    url = f"{FIRESTORE_URL}/users?pageSize=300"
    res = make_request(url)
    users = []
    if "error" not in res:
        docs = res.get("documents", [])
        for d in docs:
            uid = d.get("name", "").split("/")[-1]
            fields = decode_firestore_fields(d.get("fields", {}))
            fields["uid"] = fields.get("uid") or uid
            fields["_source"] = "firestore"
            users.append(fields)

    # Combina con Firebase Auth como fuente confiable
    auth_users = get_auth_users()
    if not users:
        return auth_users

    by_uid = {u["uid"]: u for u in users}
    for au in auth_users:
        if au["uid"] not in by_uid:
            users.append(au)
        else:
            by_uid[au["uid"]]["disabled"] = au.get("disabled", False)
            by_uid[au["uid"]]["lastLoginAt"] = au.get("lastLoginAt", "-")
    return users

def find_user(identifier):
    users = get_all_users()
    ident = identifier.strip().lower()
    for u in users:
        if u.get("uid", "").lower() == ident or u.get("email", "").lower() == ident:
            return u
    return None

def update_user_fields(uid, updates):
    # 1. Actualizar Firebase Auth (Claims / Disabled)
    auth_data = {"localId": uid}
    if "isActive" in updates:
        auth_data["disableUser"] = not updates["isActive"]

    claims = {}
    if "role" in updates:
        claims["role"] = updates["role"]
    if "status" in updates:
        claims["status"] = updates["status"]
    if "accountExpiresAt" in updates:
        claims["accountExpiresAt"] = updates["accountExpiresAt"]
    if claims:
        auth_data["customAttributes"] = json.dumps(claims)

    auth_url = f"https://identitytoolkit.googleapis.com/v1/projects/{PROJECT_ID}/accounts:update"
    auth_res = make_request(auth_url, method="POST", data=auth_data)

    # 2. Actualizar Firestore (Best effort si hay cuota)
    encoded = encode_firestore_fields(updates)
    mask_params = "&".join([f"updateMask.fieldPaths={k}" for k in updates.keys()])
    fs_url = f"{FIRESTORE_URL}/users/{uid}?{mask_params}"
    fs_res = make_request(fs_url, method="PATCH", data={"fields": encoded})

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

# ─────────────────────────────────────────────────────────────────────────────
# PANEL WEB LOCAL MODERNO
# ─────────────────────────────────────────────────────────────────────────────

WEB_HTML = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inútil Admin — Control de Licencias Firebase</title>
<style>
  :root {
    --bg: #090a0f;
    --surface: #12141c;
    --border: #1f2333;
    --accent: #18C75A;
    --amber: #E8B949;
    --danger: #FF4757;
    --text: #F5F7F5;
    --sub: #8E95A5;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; padding: 24px; }
  .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border); }
  .logo { font-size: 22px; font-weight: 800; display: flex; align-items: center; gap: 8px; }
  .logo span { color: var(--amber); }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 24px; }
  .stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 14px; padding: 16px; }
  .stat-title { font-size: 12px; color: var(--sub); text-transform: uppercase; letter-spacing: 0.5px; }
  .stat-val { font-size: 28px; font-weight: 800; margin-top: 6px; }
  .toolbar { display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap; }
  .search { flex: 1; min-width: 260px; background: var(--surface); border: 1px solid var(--border); padding: 10px 14px; border-radius: 10px; color: #fff; font-size: 14px; }
  .btn { background: var(--surface); border: 1px solid var(--border); color: var(--text); padding: 9px 16px; border-radius: 10px; font-weight: 700; font-size: 13px; cursor: pointer; transition: 0.2s; }
  .btn:hover { border-color: var(--accent); }
  .btn-primary { background: var(--accent); color: #000; border-color: var(--accent); }
  .btn-amber { background: var(--amber); color: #000; border-color: var(--amber); }
  table { width: 100%; border-collapse: collapse; background: var(--surface); border-radius: 14px; overflow: hidden; border: 1px solid var(--border); }
  th, td { padding: 14px 16px; text-align: left; font-size: 13.5px; border-bottom: 1px solid var(--border); }
  th { background: #0c0e14; color: var(--sub); font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
  tr:hover { background: rgba(255,255,255,0.02); }
  .badge { display: inline-block; padding: 4px 8px; border-radius: 6px; font-size: 11px; font-weight: 800; }
  .badge-active { background: rgba(24, 199, 90, 0.15); color: var(--accent); }
  .badge-pending { background: rgba(232, 185, 73, 0.15); color: var(--amber); }
  .badge-blocked { background: rgba(255, 71, 87, 0.15); color: var(--danger); }
  .badge-admin { background: rgba(232, 185, 73, 0.25); color: var(--amber); }
  .actions { display: flex; gap: 6px; }
  .btn-sm { padding: 5px 10px; font-size: 11.5px; border-radius: 6px; }
</style>
</head>
<body>
  <div class="header">
    <div class="logo">📺 InútilTV <span>· Admin VIP</span></div>
    <div><button class="btn btn-primary" onclick="loadUsers()">🔄 Actualizar</button></div>
  </div>

  <div class="stats" id="statsRow">
    <div class="stat-card"><div class="stat-title">Usuarios Totales</div><div class="stat-val" id="totalUsers">-</div></div>
    <div class="stat-card"><div class="stat-title">Activos / Vigentes</div><div class="stat-val" style="color:var(--accent)" id="activeUsers">-</div></div>
    <div class="stat-card"><div class="stat-title">Pendientes de Aprobación</div><div class="stat-val" style="color:var(--amber)" id="pendingUsers">-</div></div>
    <div class="stat-card"><div class="stat-title">Administradores</div><div class="stat-val" style="color:var(--amber)" id="adminUsers">-</div></div>
  </div>

  <div class="toolbar">
    <input type="text" class="search" id="searchInput" placeholder="Buscar por correo, nombre o UID..." oninput="renderTable()">
    <button class="btn" onclick="filterBy('todos')">Todos</button>
    <button class="btn" onclick="filterBy('pending')">Pendientes</button>
    <button class="btn" onclick="filterBy('active')">Activos</button>
    <button class="btn" onclick="filterBy('admin')">Admins</button>
  </div>

  <table>
    <thead>
      <tr>
        <th>Usuario / Correo</th>
        <th>Rol</th>
        <th>Estado</th>
        <th>Vigencia</th>
        <th>Dispositivos</th>
        <th>Acciones Rápidas</th>
      </tr>
    </thead>
    <tbody id="userRows"></tbody>
  </table>

<script>
let allUsers = [];
let currentFilter = 'todos';

async function loadUsers() {
  const res = await fetch('/api/users');
  allUsers = await res.json();
  renderStats();
  renderTable();
}

function renderStats() {
  document.getElementById('totalUsers').innerText = allUsers.length;
  document.getElementById('activeUsers').innerText = allUsers.filter(u => u.status === 'active' || u.role === 'admin').length;
  document.getElementById('pendingUsers').innerText = allUsers.filter(u => u.status === 'pending' && u.role !== 'admin').length;
  document.getElementById('adminUsers').innerText = allUsers.filter(u => u.role === 'admin').length;
}

function filterBy(f) {
  currentFilter = f;
  renderTable();
}

function renderTable() {
  const query = document.getElementById('searchInput').value.toLowerCase();
  const tbody = document.getElementById('userRows');
  tbody.innerHTML = '';

  const filtered = allUsers.filter(u => {
    const textMatch = (u.email || '').toLowerCase().includes(query) || (u.displayName || '').toLowerCase().includes(query) || (u.uid || '').toLowerCase().includes(query);
    if (!textMatch) return false;
    if (currentFilter === 'pending') return u.status === 'pending';
    if (currentFilter === 'active') return u.status === 'active' || u.role === 'admin';
    if (currentFilter === 'admin') return u.role === 'admin';
    return true;
  });

  filtered.forEach(u => {
    const tr = document.createElement('tr');
    const isAdm = u.role === 'admin';
    const stBadge = isAdm ? '<span class="badge badge-admin">ADMIN</span>' : (u.status === 'active' ? '<span class="badge badge-active">ACTIVA</span>' : (u.status === 'pending' ? '<span class="badge badge-pending">PENDIENTE</span>' : '<span class="badge badge-blocked">SUSPENDIDA</span>'));
    const expText = u.accountExpiresAt ? (u.accountExpiresAt.startsWith('209') ? '💎 Permanente' : u.accountExpiresAt.substring(0, 10)) : 'Sin fecha';
    const devs = [u.currentSmartTvDeviceId ? '📺 TV' : null, u.currentTvDeviceId ? '📱 Móvil TV' : null, u.currentPhoneDeviceId ? '🎧 Music' : null].filter(Boolean).join(' · ') || 'Ninguno';

    tr.innerHTML = `
      <td><strong>${u.displayName || 'Usuario'}</strong><br><small style="color:var(--sub)">${u.email}</small></td>
      <td><span class="badge ${isAdm ? 'badge-admin' : ''}">${u.role}</span></td>
      <td>${stBadge}</td>
      <td>${expText}</td>
      <td><small style="color:var(--sub)">${devs}</small></td>
      <td>
        <div class="actions">
          <button class="btn btn-sm btn-primary" onclick="actionUser('${u.uid}', 'aprobar', 30)">+30d</button>
          <button class="btn btn-sm btn-amber" onclick="actionUser('${u.uid}', 'permanente')">💎 Perm</button>
          <button class="btn btn-sm" onclick="actionUser('${u.uid}', 'liberar')">Liberar</button>
          <button class="btn btn-sm" style="color:var(--danger)" onclick="actionUser('${u.uid}', '${u.isActive ? "suspender" : "activar"}')">${u.isActive ? 'Pausa' : 'Activar'}</button>
        </div>
      </td>
    `;
    tbody.appendChild(tr);
  });
}

async function actionUser(uid, action, val) {
  const res = await fetch('/api/action', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({uid, action, val})
  });
  const data = await res.json();
  if (data.ok) {
    loadUsers();
  } else {
    alert('Error: ' + data.error);
  }
}

loadUsers();
</script>
</body>
</html>
"""

class AdminHttpHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/" or url.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(WEB_HTML.encode("utf-8"))
        elif url.path == "/api/users":
            users = get_all_users()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(users).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/api/action":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8")
            payload = json.loads(body)
            uid = payload.get("uid")
            action = payload.get("action")
            val = payload.get("val")

            user = find_user(uid)
            if not user:
                self.send_json({"ok": False, "error": "Usuario no encontrado"})
                return

            if action == "aprobar":
                days = int(val or 30)
                now = datetime.datetime.now(datetime.timezone.utc)
                exp = (now + datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
                res = update_user_fields(uid, {
                    "status": "active",
                    "isActive": True,
                    "accountExpiresAt": exp,
                    "accountDurationDays": days,
                })
                self.send_json({"ok": "error" not in res, "res": res})
            elif action == "permanente":
                res = update_user_fields(uid, {
                    "status": "active",
                    "isActive": True,
                    "accountExpiresAt": "2099-12-31T23:59:59Z",
                    "accountDurationDays": 36500,
                })
                self.send_json({"ok": "error" not in res, "res": res})
            elif action == "liberar":
                res = update_user_fields(uid, {
                    "currentPhoneDeviceId": "",
                    "currentTvDeviceId": "",
                    "currentSmartTvDeviceId": "",
                    "pairedTvDeviceId": "",
                    "phoneSwitchCount": 0,
                })
                self.send_json({"ok": "error" not in res, "res": res})
            elif action == "suspender":
                res = update_user_fields(uid, {"isActive": False, "status": "blocked"})
                self.send_json({"ok": "error" not in res, "res": res})
            elif action == "activar":
                res = update_user_fields(uid, {"isActive": True, "status": "active"})
                self.send_json({"ok": "error" not in res, "res": res})
            else:
                self.send_json({"ok": False, "error": f"Acción desconocida: {action}"})

    def send_json(self, data):
        self.send_response(200)
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
    print(f"   👉 http://localhost:{port}")
    print(f"   👉 http://192.168.100.23:{port} (desde tu red local)")
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
    elif args.command == "web":
        cmd_web(args)

if __name__ == "__main__":
    main()
