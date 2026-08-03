#!/bin/bash
set -euo pipefail

# PoolForge Installer for Ubuntu LTS
# Usage: curl -sSL https://github.com/Paul-Cradduck/PoolForge-Releases/releases/latest/download/install.sh | sudo bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "╔══════════════════════════════════╗"
echo "║       PoolForge Installer        ║"
echo "╚══════════════════════════════════╝"

# Check root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: must run as root${NC}"
  exit 1
fi

# Check Ubuntu
if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  echo -e "${RED}Error: Ubuntu LTS required${NC}"
  exit 1
fi

# Check architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) GOARCH="amd64" ;;
  aarch64|arm64) GOARCH="arm64" ;;
  *)
    echo -e "${RED}Error: unsupported architecture $ARCH${NC}"
    exit 1
    ;;
esac

echo "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq mdadm lvm2 smartmontools samba nfs-kernel-server curl > /dev/null 2>&1
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Phase 5: Disable mdadm systemd services so PoolForge controls array assembly
MDADM_SERVICES="mdmonitor.service mdadm.service mdadm-waitidle.service"
for svc in $MDADM_SERVICES; do
  if systemctl list-unit-files "$svc" &>/dev/null; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
    echo -e "${GREEN}✓ Disabled mdadm service: $svc${NC}"
  else
    echo "  mdadm service not found (skipped): $svc"
  fi
done
echo -e "${GREEN}✓ mdadm auto-assembly disabled. PoolForge will manage all array assembly.${NC}"

echo "Downloading and verifying PoolForge..."
ASSET="poolforge-linux-${GOARCH}"
REPOSITORY_URL="https://github.com/Paul-Cradduck/PoolForge-Releases"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

LATEST_RELEASE_URL=$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$REPOSITORY_URL/releases/latest") || {
  echo -e "${RED}✗ Failed to resolve the latest PoolForge release${NC}"
  exit 1
}
RELEASE_TAG=$(printf '%s' "$LATEST_RELEASE_URL" | sed -n 's|.*/releases/tag/\([^/?]*\).*|\1|p')
if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z.-]+)?$ ]]; then
  echo -e "${RED}✗ Could not determine a valid pinned release version${NC}"
  exit 1
fi
RELEASE_BASE="$REPOSITORY_URL/releases/download/${RELEASE_TAG}"
curl -fsSL "$RELEASE_BASE/SHA256SUMS" -o "$TEMP_DIR/SHA256SUMS" || {
  echo -e "${RED}✗ Failed to download release checksums${NC}"
  exit 1
}
curl -fsSL "$RELEASE_BASE/$ASSET" -o "$TEMP_DIR/$ASSET" || {
  echo -e "${RED}✗ Failed to download PoolForge binary${NC}"
  exit 1
}
CHECKSUM_LINE=$(grep -E "^[0-9a-fA-F]{64}[[:space:]]+[*]?${ASSET}$" "$TEMP_DIR/SHA256SUMS" || true)
if [ -z "$CHECKSUM_LINE" ]; then
  echo -e "${RED}✗ SHA256SUMS does not contain ${ASSET}${NC}"
  exit 1
fi
printf '%s\n' "$CHECKSUM_LINE" > "$TEMP_DIR/${ASSET}.sha256"
(cd "$TEMP_DIR" && sha256sum -c "${ASSET}.sha256") || {
  echo -e "${RED}✗ PoolForge checksum verification failed${NC}"
  exit 1
}
chmod 0755 "$TEMP_DIR/$ASSET"
BINARY_VERSION=$("$TEMP_DIR/$ASSET" --version 2>/dev/null | awk '{print $NF}')
if [ "v$BINARY_VERSION" != "$RELEASE_TAG" ]; then
  echo -e "${RED}✗ Binary version v${BINARY_VERSION} does not match release ${RELEASE_TAG}${NC}"
  exit 1
fi
if [ -f /usr/local/bin/poolforge ]; then
  cp -a /usr/local/bin/poolforge /usr/local/bin/poolforge.backup
fi
install -m 0755 "$TEMP_DIR/$ASSET" /usr/local/bin/poolforge.new
sync /usr/local/bin/poolforge.new
mv -f /usr/local/bin/poolforge.new /usr/local/bin/poolforge
echo -e "${GREEN}✓ PoolForge ${RELEASE_TAG} installed (checksum and version verified)${NC}"

# Create data directory
mkdir -p /var/lib/poolforge
echo -e "${GREEN}✓ Data directory created${NC}"

# Create systemd service
cat > /etc/systemd/system/poolforge.service << 'EOF'
[Unit]
Description=PoolForge Storage Manager
After=network.target mdadm.service lvm2-activation.service
Wants=mdadm.service lvm2-activation.service

[Service]
Type=simple
ExecStart=/usr/local/bin/poolforge serve --addr 0.0.0.0:8080
Restart=on-failure
RestartSec=5
TimeoutStopSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable poolforge
echo -e "${GREEN}✓ Systemd service created and enabled${NC}"

# Create config for auth (optional)
if [ ! -f /etc/poolforge.conf ]; then
  cat > /etc/poolforge.conf << 'EOF'
# PoolForge Configuration
# Uncomment and set credentials for web UI authentication
#POOLFORGE_USER=admin
#POOLFORGE_PASS=changeme
#POOLFORGE_ADDR=0.0.0.0:8080
#POOLFORGE_WEBHOOK=
EOF
  echo -e "${GREEN}✓ Config file created at /etc/poolforge.conf${NC}"
fi

# Update service to use config
cat > /etc/systemd/system/poolforge.service << 'EOF'
[Unit]
Description=PoolForge Storage Manager
After=network.target mdadm.service lvm2-activation.service
Wants=mdadm.service lvm2-activation.service

[Service]
Type=simple
EnvironmentFile=-/etc/poolforge.conf
ExecStart=/bin/bash -c '/usr/local/bin/poolforge serve \
  --addr ${POOLFORGE_ADDR:-0.0.0.0:8080} \
  ${POOLFORGE_USER:+--user $POOLFORGE_USER} \
  ${POOLFORGE_PASS:+--pass $POOLFORGE_PASS} \
  ${POOLFORGE_WEBHOOK:+--webhook $POOLFORGE_WEBHOOK}'
Restart=on-failure
RestartSec=5
TimeoutStopSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# Phase 5: Back up existing metadata for safe upgrade
METADATA_FILE="/var/lib/poolforge/metadata.json"
BACKUP_FILE="/var/lib/poolforge/metadata.json.pre-phase5-backup"
if [ -f "$METADATA_FILE" ] && [ ! -f "$BACKUP_FILE" ]; then
  cp "$METADATA_FILE" "$BACKUP_FILE"
  echo -e "${GREEN}✓ Metadata backed up to $BACKUP_FILE${NC}"
fi

# Phase 5: Ensure boot config has AUTO -all
if command -v poolforge &>/dev/null; then
  poolforge boot-config-regenerate 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}══════════════════════════════════════${NC}"
echo -e "${GREEN}  PoolForge installed successfully!${NC}"
echo -e "${GREEN}══════════════════════════════════════${NC}"
echo ""
echo "  Binary:   /usr/local/bin/poolforge"
echo "  Config:   /etc/poolforge.conf"
echo "  Data:     /var/lib/poolforge/"
echo "  Service:  poolforge.service"
echo ""
echo "Quick start:"
echo "  1. Edit /etc/poolforge.conf to set credentials"
echo "  2. sudo systemctl start poolforge"
echo "  3. Open http://$(hostname -I | awk '{print $1}'):8080"
echo ""
echo "CLI usage:"
echo "  poolforge pool create --name mypool --disks /dev/sda,/dev/sdb"
echo "  poolforge pool list"
echo "  poolforge pool import"
echo ""
