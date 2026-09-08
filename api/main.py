"""
HomeVault API
Runs inside the same LXC as the other services, talks to Docker socket
for container status/control, and reads /proc for system stats.

Port: 8000 (map to whatever you want in docker-compose)
Auth: Bearer token — token is generated on first boot and shown in the
dashboard "Settings" tab so the user can pair the mobile app.
"""
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from typing import Optional
import docker
import psutil
import socket
import os
import secrets
from pathlib import Path

# ---------- Auth ----------
TOKEN_FILE = Path("/data/homevault_token")
TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)

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

# ---------- Docker ----------
docker_client = docker.from_env()

# Container name → user-facing metadata
SERVICE_MAP = {
    "homevault-dashboard": {"label": "Dashboard",   "port": 80,    "path": "/"},
    "nextcloud":           {"label": "Nextcloud",   "port": 8080,  "path": "/"},
    "adguard":             {"label": "AdGuard",     "port": 8053,  "path": "/"},
    "uptime-kuma":         {"label": "Uptime Kuma", "port": 3001,  "path": "/"},
    "portainer":           {"label": "Portainer",   "port": 9000,  "path": "/"},
    "jellyfin":            {"label": "Jellyfin",    "port": 8096,  "path": "/"},
    "wireguard":           {"label": "WireGuard",   "port": 51820, "path": None},
}

# ---------- App ----------
app = FastAPI(title="HomeVault API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # LAN only — dashboard + Flutter app
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------- Models ----------
class ServiceOut(BaseModel):
    name: str
    label: str
    status: str          # running | stopped | missing
    port: Optional[int]
    path: Optional[str]
    uptime_seconds: Optional[int] = None

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
        c = docker_client.containers.get(name)
        started = c.attrs["State"].get("StartedAt")
        return ServiceOut(
            name=name,
            label=meta["label"],
            status="running" if c.status == "running" else "stopped",
            port=meta["port"],
            path=meta["path"],
        )
    except docker.errors.NotFound:
        return ServiceOut(name=name, label=meta["label"], status="missing",
                          port=meta["port"], path=meta["path"])

# ---------- Public endpoints (no auth) ----------
@app.get("/api/health")
def health():
    return {"status": "ok", "service": "homevault-api"}

@app.get("/api/info")
def info():
    """Basic info exposed for discovery (used by app's pairing screen)."""
    return {
        "name": "HomeVault",
        "version": "1.0.0",
        "hostname": socket.gethostname(),
        "ip": get_lan_ip(),
    }

# ---------- Protected endpoints ----------
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
        docker_client.containers.get(name).start()
        return ActionResult(ok=True, message=f"{name} started")
    except docker.errors.NotFound:
        raise HTTPException(404, "Service not installed")
    except Exception as e:
        return ActionResult(ok=False, message=str(e))

@app.post("/api/services/{name}/stop", response_model=ActionResult)
def stop_service(name: str, _=Depends(verify_token)):
    try:
        docker_client.containers.get(name).stop()
        return ActionResult(ok=True, message=f"{name} stopped")
    except docker.errors.NotFound:
        raise HTTPException(404, "Service not installed")
    except Exception as e:
        return ActionResult(ok=False, message=str(e))

@app.post("/api/services/{name}/restart", response_model=ActionResult)
def restart_service(name: str, _=Depends(verify_token)):
    try:
        docker_client.containers.get(name).restart()
        return ActionResult(ok=True, message=f"{name} restarted")
    except docker.errors.NotFound:
        raise HTTPException(404, "Service not installed")
    except Exception as e:
        return ActionResult(ok=False, message=str(e))

@app.get("/api/system/stats", response_model=SystemStats)
def system_stats(_=Depends(verify_token)):
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    return SystemStats(
        hostname=socket.gethostname(),
        ip=get_lan_ip(),
        cpu_percent=psutil.cpu_percent(interval=0.3),
        memory_used_mb=int((mem.total - mem.available) / 1024 / 1024),
        memory_total_mb=int(mem.total / 1024 / 1024),
        disk_used_gb=round((disk.total - disk.free) / 1024**3, 1),
        disk_total_gb=round(disk.total / 1024**3, 1),
        uptime_seconds=int(psutil.boot_time()),
    )

@app.get("/api/system/token")
def get_token(_=Depends(verify_token)):
    """Return the current token (used by dashboard 'Settings' to show QR)."""
    return {"token": API_TOKEN}

@app.post("/api/system/reboot", response_model=ActionResult)
def reboot(_=Depends(verify_token)):
    os.system("shutdown -r now")
    return ActionResult(ok=True, message="Rebooting")
