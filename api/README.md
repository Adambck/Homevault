# HomeVault API

FastAPI service running in the same LXC as the other HomeVault containers.
Talks to Docker via the mounted socket, reads system stats via `psutil`.

## Endpoints

### Public (no auth)

| Method | Path            | Purpose                                     |
|--------|-----------------|---------------------------------------------|
| GET    | `/api/health`   | Liveness probe                              |
| GET    | `/api/info`     | Discovery (name, version, hostname, IP) — used by the mobile app pairing flow |

### Protected (Bearer token)

Header: `Authorization: Bearer <token>`

| Method | Path                                | Purpose                          |
|--------|-------------------------------------|----------------------------------|
| GET    | `/api/services`                     | List all services + status       |
| GET    | `/api/services/{name}`              | One service's status             |
| POST   | `/api/services/{name}/start`        | Start a container                |
| POST   | `/api/services/{name}/stop`         | Stop a container                 |
| POST   | `/api/services/{name}/restart`      | Restart a container              |
| GET    | `/api/system/stats`                 | CPU, memory, disk, uptime        |
| GET    | `/api/system/token`                 | Return the current token         |
| POST   | `/api/system/reboot`                | Reboot the host                  |

## Token

On first boot the API generates a random token and writes it to
`/data/homevault_token` (persisted via named volume). Show the token
in the dashboard's "Settings" tab as a QR code so the mobile app can
scan it to pair.

## Local test

```bash
cd api
pip install -r requirements.txt
uvicorn main:app --reload
# → http://127.0.0.1:8000/docs for Swagger UI
```

## Deploy

Copy `docker-compose.snippet.yml` into your `install.sh`-generated
compose file, or run:

```bash
docker compose -f docker-compose.snippet.yml up -d --build
```

Then `docker exec homevault-api cat /data/homevault_token` to grab the
initial token.
