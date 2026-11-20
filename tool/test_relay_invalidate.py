#!/usr/bin/env python3
"""Tests de la capa de invalidacion del panel admin (`relay_invalidate`).

Sin red y sin cuota: se sustituye `_do_request` (la escritura a Google) y
`urllib.request.urlopen` (el aviso a las capas de cache), asi que se puede
correr en cualquier momento sin gastar escrituras de la cuota Spark.

    python3 tool/test_relay_invalidate.py      ->  exit 0 y "N/N ok"

Que se comprueba (los 5 casos que le importan a Cesar):
  1. `fs_doc_path` extrae el path RELATIVO que guardan las tablas `docs` de
     las dos capas (`users/<uid>`), no el path de Google completo.
  2. Un PATCH de `update_user_fields` avisa a las DOS capas con
     `POST /admin/invalidate {"path": ...}` + `X-Admin-Secret`.
  3. Una lectura (GET) NO avisa: purgar sin escribir cuesta una lectura pagada.
  4. Si la escritura ya paso por una capa (`FB_API_BASE` apuntando a ella),
     esa capa se omite: purgarla le costaria re-pagar la lectura que acaba de
     servir, y ademas el relay ya actualizo su propio cache (`relay.py:1094`).
  5. Una escritura RECHAZADA por Google (respuesta con `error`) no avisa a
     nadie, y `RELAY_INVALIDATE=0` apaga el aviso por completo.
"""
import importlib.util
import json
import os
import sys
import urllib.request
from pathlib import Path

# El modulo lee estas variables al importarse, asi que van ANTES del import.
os.environ["RELAY_INVALIDATE_BASES"] = "http://s7.test:8080,https://cloud.test"
os.environ["RELAY_ADMIN_SECRET"] = "llave-de-prueba"
os.environ["RELAY_INVALIDATE"] = "1"
os.environ.pop("FB_API_BASE", None)

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("fadmin", HERE / "firebase_admin.py")
fa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fa)

CALLS = []           # avisos a /admin/invalidate: (url, body, header)
WRITES = []          # escrituras "a Google" que simulamos: (url, method)
FAKE_STATUS = {}     # base -> codigo a devolver (default 200)


class FakeResponse:
    def __init__(self, status):
        self.status = status

    def read(self):
        return b"{}"

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_urlopen(req, timeout=None):
    body = json.loads(req.data.decode()) if req.data else {}
    # `urllib.request.Request` capitaliza las cabeceras (`X-Admin-Secret` ->
    # `X-admin-secret`), y las dos capas leen con `headers.get(...)` que es
    # case-insensitive (HTTP/1.1 lo exige). Se normaliza aqui para no
    # confundir un case-folding de urllib con un fallo real de la llave.
    hdrs = {k.lower(): v for k, v in req.headers.items() if v is not None}
    CALLS.append((req.full_url, body, hdrs.get("x-admin-secret")))
    base = req.full_url.rsplit("/admin/", 1)[0]
    return FakeResponse(FAKE_STATUS.get(base, 200))


def fake_do_request(url, method="GET", data=None, token=None):
    WRITES.append((url, method))
    return {"ok": True}


fa.urllib.request.urlopen = fake_urlopen
fa._do_request = fake_do_request

RESULTS = []


def check(name, got, expected):
    ok = got == expected
    RESULTS.append((name, ok, got, expected))
    if not ok:
        print(f"  FALLO {name}\n    got      {got!r}\n    expected {expected!r}")
    return ok


FS = fa.FIRESTORE_URL
PATCH_URL = f"{FS}/users/uid123?updateMask.fieldPaths=status&updateMask.fieldPaths=isActive"

# --- 1. extraccion de path -------------------------------------------------
check("1a path de documento simple",
      fa.fs_doc_path(PATCH_URL), "users/uid123")
check("1b subcoleccion",
      fa.fs_doc_path(f"{FS}/users/uid123/tv_remote/state"),
      "users/uid123/tv_remote/state")
check("1c URL de Auth no es documento",
      fa.fs_doc_path("https://identitytoolkit.googleapis.com/v1/projects/x/accounts:update"),
      None)
check("1d coleccion suelta (list) no es documento",
      fa.fs_doc_path(f"{FS}/users?pageSize=300"), None)

# --- 2. PATCH avisa a las dos capas ---------------------------------------
CALLS.clear(); WRITES.clear()
fa.make_request(PATCH_URL, method="PATCH", data={"fields": {}}, token="t")
check("2a avisa a las dos capas", len(CALLS), 2)
check("2b path purgado", [c[1].get("path") for c in CALLS],
      ["users/uid123", "users/uid123"])
check("2c URL del aviso", [c[0] for c in CALLS],
      ["http://s7.test:8080/admin/invalidate", "https://cloud.test/admin/invalidate"])
check("2d llave enviada", set(c[2] for c in CALLS), {"llave-de-prueba"})

# --- 3. GET no avisa -------------------------------------------------------
CALLS.clear(); WRITES.clear()
fa.make_request(f"{FS}/users?pageSize=300", method="GET", token="t")
check("3a lectura no purga nada", CALLS, [])

# --- 4. escritura por relay: esa capa se omite -----------------------------
CALLS.clear(); WRITES.clear()
old_fs = fa.FIRESTORE_URL
fa.FIRESTORE_URL = "http://s7.test:8080/v1/projects/p/databases/(default)/documents"
relay_url = f"{fa.FIRESTORE_URL}/users/uid123?updateMask.fieldPaths=status"
fa.make_request(relay_url, method="PATCH", data={"fields": {}}, token="t")
check("4a no se purga la capa por donde ya escribio",
      [c[0] for c in CALLS], ["https://cloud.test/admin/invalidate"])
fa.FIRESTORE_URL = old_fs

# --- 5. escritura rechazada y aviso apagado --------------------------------
CALLS.clear(); WRITES.clear()
fa._do_request = lambda url, method="GET", data=None, token=None: {"error": "quota", "code": 429}
fa.make_request(PATCH_URL, method="PATCH", data={"fields": {}}, token="t")
check("5a escritura rechazada no avisa", CALLS, [])
fa._do_request = fake_do_request

CALLS.clear()
os.environ["RELAY_INVALIDATE"] = "0"
fa.RELAY_INVALIDATE_ENABLED = False
fa.make_request(PATCH_URL, method="PATCH", data={"fields": {}}, token="t")
check("5b RELAY_INVALIDATE=0 apaga el aviso", CALLS, [])
os.environ["RELAY_INVALIDATE"] = "1"
fa.RELAY_INVALIDATE_ENABLED = True

# --- 6. el error de red NO tumba la escritura ------------------------------
WRITES.clear()
CALLS.clear()
FAKE_STATUS["http://s7.test:8080"] = 401


def exploding_urlopen(req, timeout=None):
    if "s7.test" in req.full_url:
        raise OSError("red inalcanzable")
    return fake_urlopen(req, timeout=timeout)


fa.urllib.request.urlopen = exploding_urlopen
res = fa.make_request(PATCH_URL, method="PATCH", data={"fields": {}}, token="t")
fa.urllib.request.urlopen = fake_urlopen
check("6a la escritura sobrevive a un fallo de purga", res, {"ok": True})
check("6b la otra capa se purgo igual", [c[0] for c in CALLS],
      ["https://cloud.test/admin/invalidate"])

# --- reporte ---------------------------------------------------------------
total = len(RESULTS)
passed = sum(1 for _, ok, _, _ in RESULTS if ok)
print(f"\n{passed}/{total} ok  (tests de invalidacion del panel admin, sin red)")
sys.exit(0 if passed == total else 1)
