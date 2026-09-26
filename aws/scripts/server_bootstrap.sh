#!/bin/bash
set -e

# Log all output for debugging in case something fails (viewable via SSH at /var/log/server_bootstrap.log)
exec > >(tee /var/log/server_bootstrap.log) 2>&1
echo "Starting Minecraft bootstrap process..."

# Variables injected by Terraform templatefile
S3_BUCKET="${s3_bucket}"
PROJECT_ID="${project_id}"

# 1. Update system & install deps (Java 17 & 21 covers most modern modpacks)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-21-jre-headless openjdk-17-jre-headless unzip wget curl jq awscli tar

useradd -r -m -U -d /opt/minecraft -s /bin/bash minecraft
mkdir -p /opt/minecraft/server
chown minecraft:minecraft /opt/minecraft/server

# 2. Install Ferium for ARM64
wget -q "https://github.com/gorilla-devs/ferium/releases/latest/download/ferium-linux-arm64-nogui.zip" -O /tmp/ferium.zip
unzip -o /tmp/ferium.zip -d /usr/local/bin/
chmod +x /usr/local/bin/ferium

# 3. Restore world from S3 if it exists
aws s3 cp s3://$S3_BUCKET/$PROJECT_ID/world.tar.gz /tmp/world.tar.gz || echo "No previous world found."
if [ -f /tmp/world.tar.gz ]; then
  tar -xzf /tmp/world.tar.gz -C /opt/minecraft/server
  chown -R minecraft:minecraft /opt/minecraft/server/world
fi

# 4. Add modpack via Ferium
sudo -u minecraft bash -c "
  cd /opt/minecraft/server
  mkdir -p ~/.config/ferium
  # Pipe automatically answers Ferium's interactive prompts (Output dir: /opt/minecraft/server, Install Overrides: y)
  echo -e \"/opt/minecraft/server\ny\n\" | ferium modpack add $PROJECT_ID
  ferium modpack upgrade
"

# 5. Parse CurseForge manifest.json
cd /opt/minecraft/server
if [ ! -f manifest.json ]; then
  echo "Error: manifest.json not found! Modpack download failed."
  exit 1
fi

MC_VERSION=$(jq -r '.minecraft.version' manifest.json)
LOADER_ID=$(jq -r '.minecraft.modLoaders[0].id' manifest.json)
echo "Detected Minecraft Version: $MC_VERSION"
echo "Detected Loader: $LOADER_ID"

# 6. Dynamic Loader Installation
JAVA_CMD="/usr/bin/java"

if [[ "$LOADER_ID" == fabric-* ]]; then
    LOADER_VERSION=$(echo $LOADER_ID | cut -d'-' -f 2)
    echo "Installing Fabric $LOADER_VERSION..."
    wget -qO fabric-installer.jar https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.0.1/fabric-installer-1.0.1.jar
    sudo -u minecraft $JAVA_CMD -jar fabric-installer.jar server -mcversion "$MC_VERSION" -loader "$LOADER_VERSION" -downloadMinecraft
    
    START_CMD="$JAVA_CMD -Xmx1500M -Xms512M -jar fabric-server-launch.jar nogui"

elif [[ "$LOADER_ID" == forge-* ]]; then
    LOADER_VERSION=$(echo $LOADER_ID | cut -d'-' -f 2)
    echo "Installing Forge $LOADER_VERSION..."
    wget -qO forge-installer.jar "https://maven.minecraftforge.net/net/minecraftforge/forge/$MC_VERSION-$LOADER_VERSION/forge-$MC_VERSION-$LOADER_VERSION-installer.jar"
    sudo -u minecraft $JAVA_CMD -jar forge-installer.jar --installServer
    
    # Modern Forge uses run.sh, older Forge uses a jar
    if [ -f run.sh ]; then
        echo "-Xmx1500M" > user_jvm_args.txt
        echo "-Xms512M" >> user_jvm_args.txt
        START_CMD="bash run.sh"
    else
        START_JAR=$(ls forge-*.jar | head -n 1)
        START_CMD="$JAVA_CMD -Xmx1500M -Xms512M -jar $START_JAR nogui"
    fi
    
elif [[ "$LOADER_ID" == neoforge-* ]]; then
    LOADER_VERSION=$(echo $LOADER_ID | cut -d'-' -f 2)
    echo "Installing NeoForge $LOADER_VERSION..."
    wget -qO neoforge-installer.jar "https://maven.neoforged.net/releases/net/neoforged/neoforge/$LOADER_VERSION/neoforge-$LOADER_VERSION-installer.jar"
    sudo -u minecraft $JAVA_CMD -jar neoforge-installer.jar --installServer
    
    if [ -f run.sh ]; then
        echo "-Xmx1500M" > user_jvm_args.txt
        echo "-Xms512M" >> user_jvm_args.txt
        START_CMD="bash run.sh"
    else
        START_JAR=$(ls neoforge-*.jar | head -n 1)
        START_CMD="$JAVA_CMD -Xmx1500M -Xms512M -jar $START_JAR nogui"
    fi
fi

# 7. Agree to EULA
echo "eula=true" > eula.txt
chown -R minecraft:minecraft /opt/minecraft/server

# 8. Create S3 Backup Script (Fires when server stops)
cat << SCRIPT > /opt/minecraft/server/backup.sh
#!/bin/bash
echo "Zipping world data..."
tar -czf /tmp/world.tar.gz -C /opt/minecraft/server world
echo "Uploading to S3..."
aws s3 cp /tmp/world.tar.gz s3://$S3_BUCKET/$PROJECT_ID/world.tar.gz
SCRIPT
chmod +x /opt/minecraft/server/backup.sh
chown minecraft:minecraft /opt/minecraft/server/backup.sh

# 9. Setup Systemd Service
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

systemctl daemon-reload
systemctl enable minecraft
systemctl start minecraft