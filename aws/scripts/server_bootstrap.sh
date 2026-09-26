#!/bin/bash
set -e

exec > >(tee /var/log/server_bootstrap.log) 2>&1
echo "Starting Minecraft bootstrap process..."

S3_BUCKET="${s3_bucket}"
PROJECT_ID="${project_id}"
DISCORD_WEBHOOK_URL="${discord_webhook_url}"

# --- DISCORD HELPER FUNCTION ---
send_discord_alert() {
  local title="$1"
  local description="$2"
  local color="$3"
  
  if [ -n "$DISCORD_WEBHOOK_URL" ]; then
    curl -s -H "Content-Type: application/json" \
      -X POST \
      -d '{
        "embeds": [{
          "title": "'"$title"'",
          "description": "'"$description"'",
          "color": '"$color"',
          "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
        }]
      }' "$DISCORD_WEBHOOK_URL" > /dev/null
  fi
}

send_discord_alert "Server Launching" "Provisioning AWS Instance for Modpack ID: \`$PROJECT_ID\`. Bootstrapping environment..." 3447003

# 1. Update system & install deps
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-21-jre-headless openjdk-17-jre-headless unzip wget curl jq awscli tar python3-pip
pip3 install --break-system-packages mcstatus

useradd -r -m -U -d /opt/minecraft -s /bin/bash minecraft
mkdir -p /opt/minecraft/server
chown minecraft:minecraft /opt/minecraft/server

# 2. Install Ferium
wget -q "https://github.com/gorilla-devs/ferium/releases/latest/download/ferium-linux-arm64-nogui.zip" -O /tmp/ferium.zip
unzip -o /tmp/ferium.zip -d /usr/local/bin/
chmod +x /usr/local/bin/ferium

# 3. Restore world and configurations from S3
aws s3 cp s3://$S3_BUCKET/$PROJECT_ID/world.tar.gz /tmp/world.tar.gz || echo "No previous world found."
if [ -f /tmp/world.tar.gz ]; then
  tar -xzf /tmp/world.tar.gz -C /opt/minecraft/server
fi

# Sync configs (Feature D)
aws s3 sync s3://$S3_BUCKET/$PROJECT_ID/config/ /opt/minecraft/server/ || echo "No existing configs found in S3."

# Ensure fallback server.properties exists if not downloaded
if [ ! -f /opt/minecraft/server/server.properties ]; then
  cat << 'EOF' > /opt/minecraft/server/server.properties
enable-command-block=true
spawn-protection=0
view-distance=10
difficulty=normal
motd=Ephemeral Modded Minecraft Server
EOF
fi

chown -R minecraft:minecraft /opt/minecraft/server

# 4. Add modpack via Ferium
sudo -u minecraft bash -c "
  cd /opt/minecraft/server
  mkdir -p ~/.config/ferium
  echo -e \"/opt/minecraft/server\ny\n\" | ferium modpack add $PROJECT_ID
  ferium modpack upgrade
"

# 5. Parse Manifest & Install Loader
cd /opt/minecraft/server
if [ ! -f manifest.json ]; then
  send_discord_alert "Server Launch Failed" "Critical Error: \`manifest.json\` not found after Ferium download." 16711680
  exit 1
fi

MC_VERSION=$(jq -r '.minecraft.version' manifest.json)
LOADER_ID=$(jq -r '.minecraft.modLoaders[0].id' manifest.json)
JAVA_CMD="/usr/bin/java"

if [[ "$LOADER_ID" == fabric-* ]]; then
    LOADER_VERSION=$(echo$LOADER_ID | cut -d'-' -f 2)
    wget -qO fabric-installer.jar https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.0.1/fabric-installer-1.0.1.jar
    sudo -u minecraft $JAVA_CMD -jar fabric-installer.jar server -mcversion "$MC_VERSION" -loader "$LOADER_VERSION" -downloadMinecraft
    START_CMD="$JAVA_CMD -Xmx1500M -Xms512M -jar fabric-server-launch.jar nogui"
    
elif [[ "$LOADER_ID" == forge-* ]]; then
    LOADER_VERSION=$(echo$LOADER_ID | cut -d'-' -f 2)
    wget -qO forge-installer.jar "https://maven.minecraftforge.net/net/minecraftforge/forge/$MC_VERSION-$LOADER_VERSION/forge-$MC_VERSION-$LOADER_VERSION-installer.jar"
    sudo -u minecraft $JAVA_CMD -jar forge-installer.jar --installServer
    if [ -f run.sh ]; then
        echo "-Xmx1500M" > user_jvm_args.txt
        echo "-Xms512M" >> user_jvm_args.txt
        START_CMD="bash run.sh"
    else
        START_JAR=$(ls forge-*.jar | head -n 1)
        START_CMD="$JAVA_CMD -Xmx1500M -Xms512M -jar$START_JAR nogui"
    fi
    
elif [[ "$LOADER_ID" == neoforge-* ]]; then
    LOADER_VERSION=$(echo$LOADER_ID | cut -d'-' -f 2)
    wget -qO neoforge-installer.jar "https://maven.neoforged.net/releases/net/neoforged/neoforge/$LOADER_VERSION/neoforge-$LOADER_VERSION-installer.jar"
    sudo -u minecraft $JAVA_CMD -jar neoforge-installer.jar --installServer
    if [ -f run.sh ]; then
        echo "-Xmx1500M" > user_jvm_args.txt
        echo "-Xms512M" >> user_jvm_args.txt
        START_CMD="bash run.sh"
    else
        START_JAR=$(ls neoforge-*.jar | head -n 1)
        START_CMD="$JAVA_CMD -Xmx1500M -Xms512M -jar$START_JAR nogui"
    fi
fi

echo "eula=true" > eula.txt
chown -R minecraft:minecraft /opt/minecraft/server

# 6. Create Backup Script
cat << SCRIPT > /opt/minecraft/server/backup.sh
#!/bin/bash
echo "Zipping world data..."
tar -czf /tmp/world.tar.gz -C /opt/minecraft/server world
aws s3 cp /tmp/world.tar.gz s3://$S3_BUCKET/$PROJECT_ID/world.tar.gz

# Backup configs (Feature D)
for file in server.properties ops.json whitelist.json banned-players.json banned-ips.json usercache.json; do
  if [ -f /opt/minecraft/server/\$file ]; then
    aws s3 cp /opt/minecraft/server/\$file s3://$S3_BUCKET/$PROJECT_ID/config/\$file
  fi
done

curl -s -H "Content-Type: application/json" -X POST \
  -d '{"embeds": [{"title": "Server Offline", "description": "World safely backed up to S3. EC2 instance terminating.", "color": 16711680, "timestamp": "'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}]}' \
  "$DISCORD_WEBHOOK_URL" > /dev/null
SCRIPT
chmod +x /opt/minecraft/server/backup.sh
chown minecraft:minecraft /opt/minecraft/server/backup.sh

# 7. Setup Systemd Service
cat << SERVICE > /etc/systemd/system/minecraft.service
[Unit]
Description=Minecraft Server
After=network.target

[Service]
User=minecraft
WorkingDirectory=/opt/minecraft/server
ExecStart=$START_CMD
SuccessExitStatus=143
TimeoutStopSec=120
ExecStopPost=/opt/minecraft/server/backup.sh

[Install]
WantedBy=multi-user.target
SERVICE

# 8. Setup Online Notifier
cat << SCRIPT > /opt/minecraft/discord_notifier.sh
#!/bin/bash
PUBLIC_IP=\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
until nc -z 127.0.0.1 25565; do
  sleep 5
done
curl -s -H "Content-Type: application/json" -X POST \
  -d '{"embeds": [{"title": "Server Online!", "description": "Server is up and accepting connections.\n\n**IP Address:** \`'\$PUBLIC_IP':25565\`", "color": 65280, "timestamp": "'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}]}' \
  "$DISCORD_WEBHOOK_URL" > /dev/null
SCRIPT
chmod +x /opt/minecraft/discord_notifier.sh

cat << SERVICE > /etc/systemd/system/minecraft-notifier.service
[Unit]
Description=Minecraft Discord Notifier
After=minecraft.service

[Service]
Type=oneshot
User=root
ExecStart=/opt/minecraft/discord_notifier.sh

[Install]
WantedBy=multi-user.target
SERVICE

# 9. Setup Auto-shutdown daemon
cat << 'EOF' > /opt/minecraft/autoshutdown.sh
#!/bin/bash
IDLE_LIMIT=20
CHECK_INTERVAL=60
INITIAL_GRACE_PERIOD=900
sleep $INITIAL_GRACE_PERIOD
IDLE_MINUTES=0

while true; do
  ONLINE=$(mcstatus 127.0.0.1:25565 json 2>/dev/null | jq -r '.players.online // empty')
  if [ -z "$ONLINE" ]; then
    echo "Could not reach server."
  elif [ "$ONLINE" -eq 0 ]; then
    IDLE_MINUTES=$((IDLE_MINUTES + 1))
  else
    IDLE_MINUTES=0
  fi
  if [ "$IDLE_MINUTES" -ge "$IDLE_LIMIT" ]; then
    systemctl stop minecraft
    shutdown -h now
    exit 0
  fi
  sleep $CHECK_INTERVAL
done
EOF
chmod +x /opt/minecraft/autoshutdown.sh
chown minecraft:minecraft /opt/minecraft/autoshutdown.sh

cat << 'SERVICE' > /etc/systemd/system/minecraft-autoshutdown.service
[Unit]
Description=Minecraft Inactivity Auto-Shutdown
After=minecraft.service

[Service]
Type=simple
User=root
ExecStart=/opt/minecraft/autoshutdown.sh
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
SERVICE

# 10. Start Services
systemctl daemon-reload
systemctl enable minecraft minecraft-notifier minecraft-autoshutdown
systemctl start minecraft
systemctl start minecraft-notifier
systemctl start minecraft-autoshutdown