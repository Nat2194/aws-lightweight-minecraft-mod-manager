#!/bin/bash

LOG_FILE="/var/log/minecraft_debug.log"
exec > >(tee "$LOG_FILE") 2>&1

echo "======================================================"
echo "      Minecraft Ephemeral Server Diagnostic Log       "
echo "      Date: $(date)                                   "
echo "======================================================"

echo -e "\n--- 1. SYSTEM RESOURCES ---"
echo "Memory Usage (Check for Out-Of-Memory risks):"
free -h
echo -e "\nDisk Usage:"
df -h /

echo -e "\n--- 2. TOOLING & DEPENDENCIES ---"
java -version 2>&1 | head -n 1 || echo "ERROR: Java not installed"
/usr/local/bin/aws --version || echo "ERROR: AWS CLI not installed"
/usr/local/bin/ferium --version || echo "ERROR: Ferium not installed"

echo -e "\n--- 3. DIRECTORY & FILE INTEGRITY ---"
DIR="/opt/minecraft/server"
if [ -d "$DIR" ]; then
    echo "Server directory exists."
    [ -f "$DIR/eula.txt" ] && echo "[OK] eula.txt found." || echo "[FAIL] eula.txt missing."
    [ -f "$DIR/server.properties" ] && echo "[OK] server.properties found." || echo "[FAIL] server.properties missing."
    
    # Check for start scripts or jars
    if ls "$DIR"/forge-*.jar 1> /dev/null 2>&1 || [ -f "$DIR/run.sh" ]; then
        echo "[OK] Server loader files detected."
    else
        echo "[FAIL] No Forge/Fabric/NeoForge loader found."
    fi

    # Check mods folder
    if [ -d "$DIR/mods" ]; then
        MOD_COUNT=$(ls -1 "$DIR/mods"/*.jar 2>/dev/null | wc -l)
        echo "[OK] Mods folder exists. Contains $MOD_COUNT .jar files."
    else
        echo "[FAIL] Mods folder missing."
    fi
else
    echo "[CRITICAL] Server directory $DIR does not exist!"
fi

echo -e "\n--- 4. SYSTEMD SERVICES ---"
systemctl is-active minecraft >/dev/null 2>&1 && echo "[OK] minecraft.service is RUNNING." || echo "[FAIL] minecraft.service is NOT running."
systemctl is-active minecraft-notifier >/dev/null 2>&1 && echo "[OK] minecraft-notifier.service is RUNNING/FINISHED." || echo "[FAIL] minecraft-notifier.service failed."
systemctl is-active minecraft-autoshutdown >/dev/null 2>&1 && echo "[OK] minecraft-autoshutdown.service is RUNNING." || echo "[FAIL] minecraft-autoshutdown is NOT running."

echo -e "\n--- 5. NETWORK & PORT STATUS ---"
if ss -tulpn | grep -q ":25565"; then
    echo "[OK] Port 25565 is open and listening."
else
    echo "[FAIL] Port 25565 is NOT listening. Server is offline, still booting, or crashed."
fi

echo -e "\n--- 6. RECENT MINECRAFT CRASH LOGS ---"
echo "Checking system journal for OutOfMemory or Exception errors..."
journalctl -u minecraft -n 50 --no-pager | grep -iE "exception|error|warn|oom|killed" | tail -n 10 || echo "No explicit crashes found in recent journal logs."

echo "======================================================"
echo " Diagnostic complete. Log saved to $LOG_FILE"
echo "======================================================"