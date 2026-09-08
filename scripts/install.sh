#!/bin/bash
#═══════════════════════════════════════════════════════════════
#  HomeVault Installer v3.0
#  One script to turn any Proxmox mini-PC into a HomeVault
#  
#  Usage: 
#    curl -sL https://raw.githubusercontent.com/Adambck/homevault/main/scripts/install.sh | bash
#  Or:
#    bash install.sh
#═══════════════════════════════════════════════════════════════

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
REPO="https://raw.githubusercontent.com/Adambck/homevault/main"

clear
echo -e "${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║       HOMEVAULT INSTALLER v3.0           ║"
echo "║                                          ║"
echo "║  [1] HomeVault Basic                     ║"
echo "║      Nextcloud · AdGuard · Uptime Kuma   ║"
echo "║      Portainer · Dashboard               ║"
echo "║                                          ║"
echo "║  [2] HomeVault Plus                      ║"
echo "║      Basic + Jellyfin + WireGuard        ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Choose your profile [1/2]: " PROFILE
if [[ "$PROFILE" != "1" && "$PROFILE" != "2" ]]; then
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}▶ HomeVault installation started...${NC}"
echo ""

# ── Detect network ──
GATEWAY=$(ip route | grep default | awk '{print $3}')
SUBNET=$(echo "$GATEWAY" | cut -d'.' -f1-3)
CIDR=$(ip -o -f inet addr show vmbr0 | awk '{print $4}' | cut -d'/' -f2)
CT_IP="${SUBNET}.201/${CIDR}"

echo -e "${YELLOW}   Network: gateway=${GATEWAY} container=${SUBNET}.201${NC}"
echo ""

# ── Step 1: Fix Proxmox repos ──
echo -e "${BLUE}[1/7] Fixing Proxmox repositories...${NC}"

for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    [ -f "$f" ] && sed -i 's/^deb/#deb/' "$f" 2>/dev/null || true
done
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
done

CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
[ -z "$CODENAME" ] && CODENAME="trixie"

echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
apt-get update -y > /dev/null 2>&1
echo -e "${GREEN}   ✓ Repos OK${NC}"

# ── Step 2: Download LXC template ──
echo -e "${BLUE}[2/7] Downloading LXC template...${NC}"

pveam update > /dev/null 2>&1
TEMPLATE=$(pveam available | grep "debian-12-standard" | grep "amd64" | head -1 | awk '{print $2}')
if [ -z "$TEMPLATE" ]; then
    echo -e "${RED}   ✗ No Debian 12 template found!${NC}"
    exit 1
fi

TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"
[ ! -f "$TEMPLATE_PATH" ] && pveam download local "$TEMPLATE"
echo -e "${GREEN}   ✓ Template: ${TEMPLATE}${NC}"

# ── Step 3: Create LXC container ──
echo -e "${BLUE}[3/7] Creating LXC container...${NC}"

CTID=100
pct destroy $CTID --force 2>/dev/null || true
sleep 2

pct create $CTID "$TEMPLATE_PATH" \
    --hostname homevault \
    --password homevault \
    --rootfs local-lvm:25 \
    --cores 4 \
    --memory 4096 \
    --swap 2048 \
    --net0 name=eth0,bridge=vmbr0,ip=${CT_IP},gw=${GATEWAY} \
    --features nesting=1,keyctl=1 \
    --unprivileged 0 \
    --onboot 1

echo -e "${GREEN}   ✓ Container ${CTID} created (IP: ${SUBNET}.201)${NC}"

# ── Step 4: Install Docker ──
echo -e "${BLUE}[4/7] Installing Docker...${NC}"

pct start $CTID
echo -n "   Waiting for network"
for i in $(seq 1 30); do
    if pct exec $CTID -- ping -c1 -W2 8.8.8.8 > /dev/null 2>&1; then
        echo ""
        break
    fi
    echo -n "."
    sleep 2
done

pct exec $CTID -- bash -c '
    apt-get update -y > /dev/null 2>&1
    apt-get install -y ca-certificates curl gnupg > /dev/null 2>&1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y > /dev/null 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker
'
echo -e "${GREEN}   ✓ Docker OK${NC}"

# ── Step 5: Configure services ──
echo -e "${BLUE}[5/7] Configuring services...${NC}"

DIRS="nextcloud/data nextcloud/db adguard/work adguard/conf portainer uptime-kuma dashboard"
if [[ "$PROFILE" == "2" ]]; then
    DIRS="$DIRS jellyfin/config jellyfin/media wireguard"
fi

for d in $DIRS; do
    pct exec $CTID -- mkdir -p /opt/homevault/$d
done

# Build docker-compose
COMPOSE='services:
  homevault-dashboard:
    image: nginx:alpine
    container_name: homevault-dashboard
    restart: always
    ports:
      - "80:80"
    volumes:
      - /opt/homevault/dashboard/index.html:/usr/share/nginx/html/index.html:ro

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/homevault/portainer:/data

  nextcloud-db:
    image: mariadb:10.11
    container_name: nextcloud-db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: homevault_db_root
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: homevault_db
    volumes:
      - /opt/homevault/nextcloud/db:/var/lib/mysql

  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: always
    ports:
      - "8080:80"
    environment:
      MYSQL_HOST: nextcloud-db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: homevault_db
    volumes:
      - /opt/homevault/nextcloud/data:/var/www/html
    depends_on:
      - nextcloud-db

  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: always
    ports:
      - "3000:3000"
      - "8053:80"
      - "53:53/tcp"
      - "53:53/udp"
    volumes:
      - /opt/homevault/adguard/work:/opt/adguardhome/work
      - /opt/homevault/adguard/conf:/opt/adguardhome/conf

  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: always
    ports:
      - "3001:3001"
    volumes:
      - /opt/homevault/uptime-kuma:/app/data'

if [[ "$PROFILE" == "2" ]]; then
COMPOSE="${COMPOSE}

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: always
    ports:
      - \"8096:8096\"
    volumes:
      - /opt/homevault/jellyfin/config:/config
      - /opt/homevault/jellyfin/media:/media

  wireguard:
    image: linuxserver/wireguard:latest
    container_name: wireguard
    restart: always
    cap_add:
      - NET_ADMIN
    ports:
      - \"51820:51820/udp\"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
      - SERVERURL=auto
      - PEERS=3
    volumes:
      - /opt/homevault/wireguard:/config
      - /lib/modules:/lib/modules"
fi

pct exec $CTID -- bash -c "cat > /opt/homevault/docker-compose.yml << 'DEOF'
${COMPOSE}
DEOF"

echo -e "${GREEN}   ✓ Config OK${NC}"

# ── Step 6: Download & install dashboard ──
echo -e "${BLUE}[6/7] Installing HomeVault Dashboard...${NC}"

# Try downloading from GitHub first
if pct exec $CTID -- curl -sfL "${REPO}/dashboard/index.html" -o /opt/homevault/dashboard/index.html 2>/dev/null; then
    echo -e "${GREEN}   ✓ Dashboard downloaded from GitHub${NC}"
else
    # Fallback: create a minimal dashboard
    pct exec $CTID -- bash -c 'cat > /opt/homevault/dashboard/index.html << MINEOF
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HomeVault</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:sans-serif;background:#060a12;color:#f1f5f9;display:flex;align-items:center;justify-content:center;min-height:100vh;text-align:center;padding:20px}h1{font-size:28px;margin-bottom:8px}p{color:#64748b;margin-bottom:24px}a{display:inline-block;padding:12px 24px;background:#1e293b;border:1px solid #334155;border-radius:10px;color:#e2e8f0;text-decoration:none;margin:4px;font-size:14px}</style>
</head><body><div><div style="font-size:64px;margin-bottom:16px">🏠</div><h1>HomeVault</h1><p>Your personal home server is running.</p>
<a href="http://HOSTIP:8080" target="_blank">☁️ Nextcloud</a>
<a href="http://HOSTIP:8053" target="_blank">🛡️ AdGuard</a>
<a href="http://HOSTIP:3001" target="_blank">📊 Monitoring</a>
<a href="http://HOSTIP:9000" target="_blank">🐳 Portainer</a>
</div></body></html>
MINEOF'
    pct exec $CTID -- sed -i "s/HOSTIP/${SUBNET}.201/g" /opt/homevault/dashboard/index.html
    echo -e "${YELLOW}   ⚠ Using fallback dashboard (no internet or GitHub unreachable)${NC}"
fi

echo -e "${GREEN}   ✓ Dashboard OK${NC}"

# ── Step 7: Start services ──
echo -e "${BLUE}[7/7] Starting services (this may take a few minutes)...${NC}"

pct exec $CTID -- bash -c 'cd /opt/homevault && docker compose pull' 2>&1 | tail -10
pct exec $CTID -- bash -c 'cd /opt/homevault && docker compose up -d'

echo -e "${GREEN}   ✓ All services running!${NC}"

# ── Summary ──
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       HOMEVAULT INSTALLATION COMPLETE!           ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}                                                  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  🏠 Dashboard:    http://${SUBNET}.201              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ☁️  Nextcloud:    http://${SUBNET}.201:8080        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  🛡️  AdGuard:      http://${SUBNET}.201:8053        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  📊 Uptime Kuma:  http://${SUBNET}.201:3001        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  🐳 Portainer:    http://${SUBNET}.201:9000        ${GREEN}║${NC}"
if [[ "$PROFILE" == "2" ]]; then
echo -e "${GREEN}║${NC}  🎬 Jellyfin:     http://${SUBNET}.201:8096        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  🔐 WireGuard:    UDP :51820                      ${GREEN}║${NC}"
fi
echo -e "${GREEN}║${NC}                                                  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  🖥️  Proxmox:      https://${SUBNET}.200:8006      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Container login: root / homevault               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Proxmox login:   root / (your password)         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                  ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}💡 Save this information! Change default passwords.${NC}"
echo ""
