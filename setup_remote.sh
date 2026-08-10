#!/bin/bash
# Provisions this Raspberry Pi as the Shipyard ADS-B host.
# Single-node docker compose deployment - no Swarm.
set -euo pipefail

REPO_URL="git@github.com:TheQuietBlock/Shipyard.git"
REPO_DIR="$HOME/git/Shipyard"
STACK_DIR="$REPO_DIR/flight-tracking"

echo "==> Cloning/updating repository in $REPO_DIR"
mkdir -p "$HOME/git"
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --ff-only
else
    git clone "$REPO_URL" "$REPO_DIR"
fi

echo "==> Removing the retired web-hosting stack, if still running"
# The nginx/cloudflared stack was removed from this repo. Tear down anything
# left over from it so it does not keep running unmanaged.
if [ -f "$HOME/git/Shipyard/web-hosting/docker-compose.yml" ]; then
    docker compose -f "$HOME/git/Shipyard/web-hosting/docker-compose.yml" down || true
fi
if docker ps -q --filter 'name=^cloudflared$' | grep -q .; then
    docker rm -f cloudflared || true
fi

echo "==> Installing daily update script at $HOME/update_shipyard.sh"
cat << EOF > "$HOME/update_shipyard.sh"
#!/bin/bash
set -euo pipefail
cd "$STACK_DIR"
git -C "$REPO_DIR" pull --ff-only
docker compose pull
docker compose up -d --remove-orphans
docker system prune -f
EOF
chmod +x "$HOME/update_shipyard.sh"

echo "==> Registering daily cronjob (03:00)"
(crontab -l 2>/dev/null | grep -v 'update_shipyard.sh' || true) | crontab -
(crontab -l 2>/dev/null; echo "0 3 * * * $HOME/update_shipyard.sh >> $HOME/update_shipyard.log 2>&1") | crontab -

echo "==> Checking configuration"
if [ ! -f "$STACK_DIR/.env" ]; then
    cp "$STACK_DIR/temp.env" "$STACK_DIR/.env"
    echo "WARNING: no .env found - seeded one from temp.env."
    echo "         Edit $STACK_DIR/.env and fill in the keys, then re-run"
    echo "         ~/update_shipyard.sh. Feeders will not connect until you do."
fi

echo "==> Installing RTL-SDR udev rules"
sudo cp "$STACK_DIR/60-rtl-sdr.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger

echo "==> Running initial deployment"
"$HOME/update_shipyard.sh"

echo "Done. Map should be available at http://$(hostname -I | awk '{print $1}'):8080"
