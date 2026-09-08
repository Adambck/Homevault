"""
HomeVault API v2
- Docker service control
- System stats
- Nextcloud WebDAV proxy (file management)
- AdGuard stats proxy
- Docker logs
- Config storage (Nextcloud/AdGuard credentials, etc.)
"""
from fastapi import FastAPI, Depends, HTTPException, status, UploadFile, File, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from typing import Optional
import docker
import psutil
import socket
import os
import json
import secrets
import httpx
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

# ---------- Paths ----------
DATA_DIR = Path("/data")
DATA_DIR.mkdir(parents=True, exist_ok=True)
TOKEN_FILE = DATA_DIR / "homevault_token"
CONFIG_FILE = DATA_DIR / "config.json"

# ---------- Auth ----------
def load_or_create_token() -> str:
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text().strip()
    token = secrets.token_urlsafe(32)
    TOKEN_FILE.write_text(token)
    TOKEN_FILE.chmod(0o600)
    return token

API_TOKEN = load_or_create_token()
security = HTTPBearer()

def verify_token(creds: HTTPAuthorizationCredentials = Depends(security)):
    if not secrets.compare_digest(creds.credentials, API_TOKEN):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Invalid token")
    return True

# ---------- Config storage ----------
DEFAULT_CONFIG = {
    "nextcloud_url": "http://nextcloud:8080",
    "nextcloud_user": "",
    "nextcloud_pass": "",
    "adguard_url": "http://adguard:3000",
    "adguard_user": "",
    "adguard_pass": "",
    "user_name": "",
    "language": "nl",
}

def load_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            saved = json.loads(CONFIG_FILE.read_text())
            return {**DEFAULT_CONFIG, **saved}
        except Exception:
            pass
    return DEFAULT_CONFIG.copy()

def save_config(cfg: dict):
    current = load_config()
    current.update({k: v for k, v in cfg.items() if k in DEFAULT_CONFIG})
    CONFIG_FILE.write_text(json.dumps(current, indent=2))
    CONFIG_FILE.chmod(0o600)

# ---------- Docker (lazy) ----------
_docker_client = None

def get_docker():
    global _docker_client
    if _docker_client is None:
        _docker_client = docker.from_env()
    return _docker_client

SERVICE_MAP = {
    "homevault-dashboard": {"label": "Dashboard",   "port": 80,    "path": "/"},
    "nextcloud":           {"label": "Nextcloud",   "port": 8080,  "path": "/"},
    "adguard":             {"label": "AdGuard",     "port": 8053,  "path": "/"},
    "uptime-kuma":         {"label": "Uptime Kuma", "port": 3001,  "path": "/"},
    "portainer":           {"label": "Portainer",   "port": 9000,  "path": "/"},
    "jellyfin":            {"label": "Jellyfin",    "port": 8096,  "path": "/"},
    "wireguard":           {"label": "WireGuard",   "port": 51820, "path": None},
    "homevault-api":       {"label": "HomeVault API","port": 8000, "path": "/docs"},
}

# ---------- App ----------
app = FastAPI(title="HomeVault API", version="2.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------- Models ----------
class ServiceOut(BaseModel):
    name: str
    label: str
    status: str
    port: Optional[int]
    path: Optional[str]

class SystemStats(BaseModel):
    hostname: str
    ip: str
    cpu_percent: float
    memory_used_mb: int
    memory_total_mb: int
    disk_used_gb: float
    disk_total_gb: float
    uptime_seconds: int

class ActionResult(BaseModel):
    ok: bool
    message: str

class FileEntry(BaseModel):
    name: str
    path: str
    is_dir: bool
    size: int = 0
    modified: str = ""

class ConfigUpdate(BaseModel):
    nextcloud_url: Optional[str] = None
    nextcloud_user: Optional[str] = None
    nextcloud_pass: Optional[str] = None
    adguard_url: Optional[str] = None
    adguard_user: Optional[str] = None
    adguard_pass: Optional[str] = None
    user_name: Optional[str] = None
    language: Optional[str] = None

# ---------- Helpers ----------
def get_lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()

def container_status(name: str) -> ServiceOut:
    meta = SERVICE_MAP.get(name, {"label": name, "port": None, "path": None})
    try:
        c = get_docker().containers.get(name)
        return ServiceOut(name=name, label=meta["label"],
                          status="running" if c.status == "running" else "stopped",
                          port=meta["port"], path=meta["path"])
    except docker.errors.NotFound:
        return ServiceOut(name=name, label=meta["label"], status="missing",
                          port=meta["port"], path=meta["path"])

# ---------- Public ----------
@app.get("/api/health")
def health():
    return {"status": "ok", "service": "homevault-api", "version": "2.0.0"}

@app.get("/api/info")
def info():
    return {"name": "HomeVault", "version": "2.0.0",
            "hostname": socket.gethostname(), "ip": get_lan_ip()}

# ---------- Services ----------
@app.get("/api/services", response_model=list[ServiceOut])
def list_services(_=Depends(verify_token)):
    return [container_status(name) for name in SERVICE_MAP.keys()]

@app.get("/api/services/{name}", response_model=ServiceOut)
def get_service(name: str, _=Depends(verify_token)):
    if name not in SERVICE_MAP:
        raise HTTPException(404, "Unknown service")
    return container_status(name)

@app.post("/api/services/{name}/start", response_model=ActionResult)
def start_service(name: str, _=Depends(verify_token)):
    try:
        get_docker().containers.get(name).start()
        return ActionResult(ok=True, message=f"{name} started")
    except docker.errors.NotFound:
        raise HTTPException(404, "Service not installed")
    except Exception as e:
        return ActionResult(ok=False, message=str(e))

@app.post("/api/services/{name}/stop", response_model=ActionResult)
def stop_service(name: str, _=Depends(verify_token)):
    try:
        get_docker().containers.get(name).stop()
        return ActionResult(ok=True, message=f"{name} stopped")
    except docker.errors.NotFound:
        raise HTTPException(404, "Service not installed")
    except Exception as e:
        return ActionResult(ok=False, message=str(e))

@app.post("/api/services/{name}/restart", response_model=ActionResult)
def restart_service(name: str, _=Depends(verify_token)):
    try:
        get_docker().containers.get(name).restart()
        return ActionResult(ok=True, message=f"{name} restarted")
    except docker.errors.NotFound:
        raise HTTPException(404, "Service not installed")
    except Exception as e:
        return ActionResult(ok=False, message=str(e))

@app.get("/api/services/{name}/logs")
def service_logs(name: str, lines: int = 100, _=Depends(verify_token)):
    try:
        c = get_docker().containers.get(name)
        logs = c.logs(tail=lines).decode("utf-8", errors="replace")
        return {"logs": logs}
    except docker.errors.NotFound:
        raise HTTPException(404, "Service not installed")

# ---------- System ----------
@app.get("/api/system/stats", response_model=SystemStats)
def system_stats(_=Depends(verify_token)):
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    return SystemStats(
        hostname=socket.gethostname(), ip=get_lan_ip(),
        cpu_percent=psutil.cpu_percent(interval=0.3),
        memory_used_mb=int((mem.total - mem.available) / 1024 / 1024),
        memory_total_mb=int(mem.total / 1024 / 1024),
        disk_used_gb=round((disk.total - disk.free) / 1024**3, 1),
        disk_total_gb=round(disk.total / 1024**3, 1),
        uptime_seconds=int(psutil.boot_time()),
    )

@app.get("/api/system/token")
def get_token(_=Depends(verify_token)):
    return {"token": API_TOKEN}

@app.post("/api/system/reboot", response_model=ActionResult)
def reboot(_=Depends(verify_token)):
    os.system("shutdown -r now")
    return ActionResult(ok=True, message="Rebooting")

# ---------- Config ----------
@app.get("/api/config")
def get_config(_=Depends(verify_token)):
    cfg = load_config()
    # never leak passwords back — return whether they are set
    return {
        "nextcloud_url": cfg["nextcloud_url"],
        "nextcloud_user": cfg["nextcloud_user"],
        "nextcloud_pass_set": bool(cfg["nextcloud_pass"]),
        "adguard_url": cfg["adguard_url"],
        "adguard_user": cfg["adguard_user"],
        "adguard_pass_set": bool(cfg["adguard_pass"]),
        "user_name": cfg["user_name"],
        "language": cfg["language"],
    }

@app.post("/api/config", response_model=ActionResult)
def update_config(update: ConfigUpdate, _=Depends(verify_token)):
    save_config(update.model_dump(exclude_none=True))
    return ActionResult(ok=True, message="Config saved")

# ---------- Nextcloud WebDAV proxy ----------
def _nc_dav_base(cfg: dict) -> tuple[str, tuple[str, str]]:
    url = cfg["nextcloud_url"].rstrip("/")
    user = cfg["nextcloud_user"]
    pw = cfg["nextcloud_pass"]
    if not (user and pw):
        raise HTTPException(400, "Nextcloud credentials not configured")
    return f"{url}/remote.php/dav/files/{user}", (user, pw)

def _norm_path(p: str) -> str:
    p = "/" + p.strip("/")
    return p

@app.get("/api/files", response_model=list[FileEntry])
async def list_files(path: str = "/", _=Depends(verify_token)):
    cfg = load_config()
    base, auth = _nc_dav_base(cfg)
    path = _norm_path(path)
    url = base + quote(path)
    headers = {"Depth": "1", "Content-Type": "application/xml"}
    body = """<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>"""
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.request("PROPFIND", url, content=body,
                                     headers=headers, auth=auth)
    except Exception as e:
        raise HTTPException(502, f"Nextcloud unreachable: {e}")
    if r.status_code == 401:
        raise HTTPException(401, "Nextcloud credentials rejected")
    if r.status_code == 404:
        raise HTTPException(404, "Path not found")
    if r.status_code >= 400:
        raise HTTPException(502, f"Nextcloud error {r.status_code}")

    ns = {"d": "DAV:"}
    root = ET.fromstring(r.text)
    entries: list[FileEntry] = []
    base_href = f"/remote.php/dav/files/{cfg['nextcloud_user']}"
    for resp in root.findall("d:response", ns):
        href = resp.find("d:href", ns).text or ""
        # Strip the WebDAV prefix, decode URL, resolve relative to requested path
        from urllib.parse import unquote
        rel = unquote(href).replace(base_href, "", 1) or "/"
        if rel.rstrip("/") == path.rstrip("/"):
            continue  # skip the folder itself
        propstat = resp.find("d:propstat/d:prop", ns)
        if propstat is None:
            continue
        is_dir = propstat.find("d:resourcetype/d:collection", ns) is not None
        size_el = propstat.find("d:getcontentlength", ns)
        modif_el = propstat.find("d:getlastmodified", ns)
        name = rel.rstrip("/").split("/")[-1]
        entries.append(FileEntry(
            name=name,
            path=rel.rstrip("/"),
            is_dir=is_dir,
            size=int(size_el.text) if size_el is not None and size_el.text else 0,
            modified=modif_el.text if modif_el is not None and modif_el.text else "",
        ))
    entries.sort(key=lambda e: (not e.is_dir, e.name.lower()))
    return entries

@app.get("/api/files/download")
async def download_file(path: str = Query(...), _=Depends(verify_token)):
    cfg = load_config()
    base, auth = _nc_dav_base(cfg)
    url = base + quote(_norm_path(path))
    try:
        async with httpx.AsyncClient(timeout=None) as client:
            r = await client.get(url, auth=auth)
    except Exception as e:
        raise HTTPException(502, f"Nextcloud unreachable: {e}")
    if r.status_code == 404:
        raise HTTPException(404, "File not found")
    if r.status_code >= 400:
        raise HTTPException(502, f"Nextcloud error {r.status_code}")
    filename = path.rstrip("/").split("/")[-1]
    return StreamingResponse(
        iter([r.content]),
        media_type=r.headers.get("Content-Type", "application/octet-stream"),
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )

@app.post("/api/files/upload", response_model=ActionResult)
async def upload_file(path: str = Query("/"), file: UploadFile = File(...),
                      _=Depends(verify_token)):
    cfg = load_config()
    base, auth = _nc_dav_base(cfg)
    dest = _norm_path(path).rstrip("/") + "/" + file.filename
    url = base + quote(dest)
    content = await file.read()
    try:
        async with httpx.AsyncClient(timeout=None) as client:
            r = await client.put(url, content=content, auth=auth)
    except Exception as e:
        raise HTTPException(502, f"Nextcloud unreachable: {e}")
    if r.status_code >= 400:
        raise HTTPException(502, f"Upload failed {r.status_code}")
    return ActionResult(ok=True, message=f"Uploaded {file.filename}")

@app.delete("/api/files", response_model=ActionResult)
async def delete_file(path: str = Query(...), _=Depends(verify_token)):
    cfg = load_config()
    base, auth = _nc_dav_base(cfg)
    url = base + quote(_norm_path(path))
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.delete(url, auth=auth)
    except Exception as e:
        raise HTTPException(502, f"Nextcloud unreachable: {e}")
    if r.status_code >= 400:
        raise HTTPException(502, f"Delete failed {r.status_code}")
    return ActionResult(ok=True, message="Deleted")

@app.post("/api/files/mkdir", response_model=ActionResult)
async def mkdir(path: str = Query(...), _=Depends(verify_token)):
    cfg = load_config()
    base, auth = _nc_dav_base(cfg)
    url = base + quote(_norm_path(path))
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.request("MKCOL", url, auth=auth)
    except Exception as e:
        raise HTTPException(502, f"Nextcloud unreachable: {e}")
    if r.status_code >= 400:
        raise HTTPException(502, f"Mkdir failed {r.status_code}")
    return ActionResult(ok=True, message="Folder created")

# ---------- AdGuard proxy ----------
def _adguard_auth(cfg: dict) -> tuple[str, tuple[str, str]]:
    url = cfg["adguard_url"].rstrip("/")
    user = cfg["adguard_user"]
    pw = cfg["adguard_pass"]
    if not (user and pw):
        raise HTTPException(400, "AdGuard credentials not configured")
    return url, (user, pw)

@app.get("/api/adguard/stats")
async def adguard_stats(_=Depends(verify_token)):
    cfg = load_config()
    url, auth = _adguard_auth(cfg)
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(f"{url}/control/stats", auth=auth)
    except Exception as e:
        raise HTTPException(502, f"AdGuard unreachable: {e}")
    if r.status_code == 401:
        raise HTTPException(401, "AdGuard credentials rejected")
    if r.status_code >= 400:
        raise HTTPException(502, f"AdGuard error {r.status_code}")
    return r.json()

@app.get("/api/adguard/status")
async def adguard_status(_=Depends(verify_token)):
    cfg = load_config()
    url, auth = _adguard_auth(cfg)
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(f"{url}/control/status", auth=auth)
    except Exception as e:
        raise HTTPException(502, f"AdGuard unreachable: {e}")
    if r.status_code >= 400:
        raise HTTPException(502, f"AdGuard error {r.status_code}")
    return r.json()

@app.post("/api/adguard/protection", response_model=ActionResult)
async def adguard_protection(enabled: bool, _=Depends(verify_token)):
    cfg = load_config()
    url, auth = _adguard_auth(cfg)
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.post(f"{url}/control/dns_config",
                                  json={"protection_enabled": enabled}, auth=auth)
    except Exception as e:
        raise HTTPException(502, f"AdGuard unreachable: {e}")
    if r.status_code >= 400:
        raise HTTPException(502, f"AdGuard error {r.status_code}")
    return ActionResult(ok=True, message=f"Protection {'enabled' if enabled else 'disabled'}")
