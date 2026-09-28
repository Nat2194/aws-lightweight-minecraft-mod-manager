#!/bin/bash

exec > >(tee /var/log/server_bootstrap.log) 2>&1
echo "Starting Minecraft bootstrap process..."

# 0. Create Directory and Install Debug Script IMMEDIATELY 
mkdir -p /opt/minecraft
cat << 'EOF' > /opt/minecraft/debug.sh
${debug_script_content}
EOF
chmod +x /opt/minecraft/debug.sh

S3_BUCKET="${s3_bucket}"
PROJECT_ID="${project_id}"
DISCORD_WEBHOOK_URL="${discord_webhook_url}"
S3_ENABLED="${s3_enabled}"

# --- DISCORD HELPER FUNCTION ---
send_discord_alert() {
  local title="$1"
  local description="$2"
  local color="$3"
  if [ -n "$DISCORD_WEBHOOK_URL" ]; then
    curl -s -H "Content-Type: application/json" -X POST -d '{"embeds": [{"title": "'"$title"'", "description": "'"$description"'", "color": '"$color"', "timestamp": "'$(date -u +\%Y-\%m-\%dT\%H:\%M:\%SZ)'"}]}' "$DISCORD_WEBHOOK_URL" > /dev/null
  fi
}


# 1. Update system & install deps
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-21-jre-headless openjdk-17-jre-headless unzip wget curl jq tar python3-pip expect
pip3 install --break-system-packages mcstatus

# Fetch IP securely and send Discord Launch Alert
PUBLIC_IP=$(curl -s --retry 5 --retry-delay 2 checkip.amazonaws.com)
send_discord_alert "Server Launching" "Provisioning AWS Instance for Modpack ID: \`$PROJECT_ID\`.\n\n**IP Address:** \`$PUBLIC_IP:25565\`\n\nBootstrapping environment (this takes 3-5 minutes)..." 3447003

# Conditionally install AWS CLI
if [ "$S3_ENABLED" == "true" ]; then
  echo "S3 Enabled: Installing AWS CLI..."
  curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

useradd -r -m -U -d /opt/minecraft -s /bin/bash minecraft
mkdir -p /opt/minecraft/server
chown -R minecraft:minecraft /opt/minecraft

# 2. Install Ferium
wget -q "https://github.com/gorilla-devs/ferium/releases/latest/download/ferium-linux-arm64-nogui.zip" -O /tmp/ferium.zip
unzip -o /tmp/ferium.zip -d /usr/local/bin/
chmod +x /usr/local/bin/ferium

# 3. Conditionally restore world and configurations from S3
if [ "$S3_ENABLED" == "true" ]; then
  echo "Restoring data from S3..."
  aws s3 cp s3://$S3_BUCKET/$PROJECT_ID/world.tar.gz /tmp/world.tar.gz || echo "No previous world found."
  if [ -f /tmp/world.tar.gz ]; then
    tar -xzf /tmp/world.tar.gz -C /opt/minecraft/server
  fi
  aws s3 sync s3://$S3_BUCKET/$PROJECT_ID/config/ /opt/minecraft/server/ || echo "No existing configs found in S3."
fi

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

# 4. Add modpack via Ferium using sequential Expect to handle prompts
sudo -H -u minecraft mkdir -p /opt/minecraft/.config/ferium

sudo -H -u minecraft expect -c "
  set timeout 60
  spawn ferium modpack add $PROJECT_ID
  
  expect \"installed to?\"
  sleep 1
  send \"/opt/minecraft/server\r\"
  
  expect \"overrides be installed?\"
  sleep 1
  send \"y\r\"
  
  expect eof
"

# Upgrade and capture the output to a log file
cd /opt/minecraft/server
sudo -H -u minecraft ferium modpack upgrade | tee /tmp/ferium_upgrade.log

# Strip ANSI colors from the log so we can cleanly parse it
FERIUM_OUT=$(cat /tmp/ferium_upgrade.log | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g")

# --- DYNAMIC BLOCKED MODS DOWNLOADER ---
# Extract all CurseForge URLs for blocked mods and texture packs
BLOCKED_URLS=$(echo "$FERIUM_OUT" | grep -oP "https://www.curseforge.com/minecraft/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+/download/[0-9]+")

if [ -n "$BLOCKED_URLS" ]; then
    echo "Attempting to dynamically download blocked files via CFWidget + Edge CDN..."
    mkdir -p /opt/minecraft/server/mods
    
    for URL in $BLOCKED_URLS; do
        CATEGORY=$(echo "$URL" | awk -F'/' '{print $5}')
        SLUG=$(echo "$URL" | awk -F'/' '{print $6}')
        FILE_ID=$(echo "$URL" | awk -F'/' '{print $8}')
        
        echo "Resolving filename for $SLUG..."
        sleep 1 # Respect API rate limits
        
        # Fetch the exact filename from CFWidget's public index
        FILENAME=$(curl -s "https://api.cfwidget.com/minecraft/$CATEGORY/$SLUG" | jq -r ".files[]? | select(.id==$FILE_ID) | .name")
        
        if [ -n "$FILENAME" ] && [ "$FILENAME" != "null" ]; then
            ENCODED_FILENAME=$(jq -rn --arg x "$FILENAME" '$x|@uri')
            
            # Calculate the CurseForge Edge CDN path (File ID divided by 1000)
            PART1=$((FILE_ID / 1000))
            PART2=$((FILE_ID % 1000))
            PART2_PADDED=$(printf "%03d" $PART2)
            
            CDN_URL="https://edge.forgecdn.net/files/$PART1/$PART2_PADDED/$ENCODED_FILENAME"
            
            echo "Downloading $FILENAME from Edge CDN..."
            sudo -H -u minecraft curl -sL -A "Mozilla/5.0" -o "/opt/minecraft/server/mods/$FILENAME" "$CDN_URL"
        else
            echo "[WARN] Could not resolve filename for $SLUG. Skipping."
        fi
    done
fi

# 5. Parse Versions & Install Loader
cd /opt/minecraft/server

# Extract versions directly from Ferium's text output
MC_VERSION=$(echo "$FERIUM_OUT" | grep -oP "using Minecraft \K[0-9]+\.[0-9]+(\.[0-9]+)?")
LOADER_ID=$(echo "$FERIUM_OUT" | grep -oP "with \K[a-z]+-[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?")

# Fallback to manifest if Ferium's text format changes
if [ -z "$MC_VERSION" ] || [ -z "$LOADER_ID" ]; then
  if [ -f manifest.json ]; then
    MC_VERSION=$(jq -r '.minecraft.version' manifest.json)
    LOADER_ID=$(jq -r '.minecraft.modLoaders[0].id' manifest.json)
  else
    send_discord_alert "Server Launch Failed" "Critical Error: Could not determine Minecraft and Loader versions." 16711680
    exit 1
  fi
fi

echo "Detected Minecraft Version: $MC_VERSION"
echo "Detected Loader: $LOADER_ID"

JAVA_CMD="/usr/lib/jvm/java-17-openjdk-arm64/bin/java"

if [[ "$LOADER_ID" == fabric-* ]]; then
    LOADER_VERSION=$(echo $LOADER_ID | cut -d'-' -f 2)
    wget -qO fabric-installer.jar https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.0.1/fabric-installer-1.0.1.jar
    sudo -u minecraft $JAVA_CMD -jar fabric-installer.jar server -mcversion "$MC_VERSION" -loader "$LOADER_VERSION" -downloadMinecraft
    START_CMD="$JAVA_CMD -Xmx6500M -Xms1024M -jar fabric-server-launch.jar nogui"
    
elif [[ "$LOADER_ID" == forge-* ]]; then
    LOADER_VERSION=$(echo $LOADER_ID | cut -d'-' -f 2)
    wget -qO forge-installer.jar "https://maven.minecraftforge.net/net/minecraftforge/forge/$MC_VERSION-$LOADER_VERSION/forge-$MC_VERSION-$LOADER_VERSION-installer.jar"
    sudo -u minecraft $JAVA_CMD -jar forge-installer.jar --installServer
    if [ -f run.sh ]; then
        echo "-Xmx6500M" > user_jvm_args.txt
        echo "-Xms1024M" >> user_jvm_args.txt
        START_CMD="bash run.sh"
    else
        START_JAR=$(ls forge-*.jar | head -n 1)
        START_CMD="$JAVA_CMD -Xmx6500M -Xms1024M -jar $START_JAR nogui"
    fi
    
elif [[ "$LOADER_ID" == neoforge-* ]]; then
    LOADER_VERSION=$(echo $LOADER_ID | cut -d'-' -f 2)
    wget -qO neoforge-installer.jar "https://maven.neoforged.net/releases/net/neoforged/neoforge/$LOADER_VERSION/neoforge-$LOADER_VERSION-installer.jar"
    sudo -u minecraft $JAVA_CMD -jar neoforge-installer.jar --installServer
    if [ -f run.sh ]; then
        echo "-Xmx6500M" > user_jvm_args.txt
        echo "-Xms1024M" >> user_jvm_args.txt
        START_CMD="bash run.sh"
    else
        START_JAR=$(ls neoforge-*.jar | head -n 1)
        START_CMD="$JAVA_CMD -Xmx6500M -Xms1024M -jar $START_JAR nogui"
    fi
fi

echo "eula=true" > eula.txt
chown -R minecraft:minecraft /opt/minecraft/server

# 6. Create Backup Script (Conditionally uploads to S3)
cat << SCRIPT > /opt/minecraft/server/backup.sh
#!/bin/bash
if [ "$S3_ENABLED" == "true" ]; then
  echo "Zipping world data..."
  tar -czf /tmp/world.tar.gz -C /opt/minecraft/server world
  aws s3 cp /tmp/world.tar.gz s3://$S3_BUCKET/$PROJECT_ID/world.tar.gz

  for file in server.properties ops.json whitelist.json banned-players.json banned-ips.json usercache.json; do
    if [ -f /opt/minecraft/server/\$file ]; then
      aws s3 cp /opt/minecraft/server/\$file s3://$S3_BUCKET/$PROJECT_ID/config/\$file
    fi
  done
  curl -s -H "Content-Type: application/json" -X POST -d '{"embeds": [{"title": "Server Offline", "description": "World safely backed up to S3. EC2 instance terminating.", "color": 16711680, "timestamp": "'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}]}' "$DISCORD_WEBHOOK_URL" > /dev/null
else
  echo "S3 Backup disabled. Skipping world upload."
  curl -s -H "Content-Type: application/json" -X POST -d '{"embeds": [{"title": "Server Offline", "description": "EC2 instance terminating. No world backup was created.", "color": 16711680, "timestamp": "'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}]}' "$DISCORD_WEBHOOK_URL" > /dev/null
fi
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
PUBLIC_IP=\$(curl -s --retry 5 checkip.amazonaws.com)
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