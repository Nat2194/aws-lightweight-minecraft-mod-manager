# Scheduled Roadmap Features

This document details the architecture, technical requirements, and implementation plans for Features C and D.

---

## Feature C: Discord Webhook Notifications

### Objective

Provide automated status updates in a dedicated Discord channel so players know when the server is booting, when it is online with the active IP address, and when it is shutting down and saving the world.

### Architecture

The server will send HTTP POST requests directly to a configured Discord Webhook URL using `curl`. Calls are hooked into three operational milestones:

1. **Boot Started:** Fired at the beginning of `server_bootstrap.sh`.
2. **Server Online:** Fired once Minecraft responds on port `25565`, publishing the public IP.
3. **Shutdown & Backup:** Fired inside `backup.sh` when the world is archived and sent to S3.

### Implementation Plan

1. **Configuration:**

   - Add a `discord_webhook_url` variable to `terraform/variables.tf`.
   - Pass the URL through `templatefile()` into `scripts/server_bootstrap.sh`.

2. **Discord Embed Payloads:**
   Create a reusable helper inside `scripts/server_bootstrap.sh`:

   ```bash
   send_discord_alert() {
     local title="$1"
     local description="$2"
     local color="$3" # Decimal color code (e.g., 65280 for green, 16711680 for red)

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
   ```

3. **Execution Hooks:**
   - **On start:** `send_discord_alert "Server Launching" "Setting up Modpack ID: $PROJECT_ID..." 3447003`
   - **On ready:** Extract the public IP via `curl -s http://169.254.169.254/latest/meta-data/public-ipv4` and send `send_discord_alert "Server Online!" "Join at: \`$PUBLIC_IP:25565\`" 65280`
   - **On backup:** `send_discord_alert "Server Shutting Down" "World saved to S3. Server will terminate." 16711680`

---

## Feature D: Handling Server Properties, Whitelist, and Ops

### Objective

Automatically apply customized gameplay and access settings without manual CLI intervention on each boot. This ensures operator permissions (OPs), whitelists, difficulty levels, MOTDs, and view distances are preserved or applied deterministically.

### Architecture

Configuration files are decoupled into two tiers:

1. **Global Base Configuration:** Default server options (e.g., `view-distance=10`, `difficulty=hard`, `simulation-distance=8`).
2. **Persistent S3 Overrides:** Specific `server.properties`, `ops.json`, and `whitelist.json` files stored in a designated S3 prefix: `s3://$S3_BUCKET/$PROJECT_ID/config/`.

### Implementation Plan

1. **S3 Configuration Directory Structure:**

   ```text
   s3://mc-ephemeral-worlds-<ACCOUNT_ID>/
   └── <PROJECT_ID>/
       ├── world.tar.gz
       └── config/
           ├── ops.json
           ├── whitelist.json
           └── server.properties
   ```

2. **Bootstrap Sync Logic:**
   In `scripts/server_bootstrap.sh`, inject a sync task before the server launch command:

   ```bash
   # Sync custom configuration from S3 if present
   aws s3 sync s3://$S3_BUCKET/$PROJECT_ID/config/ /opt/minecraft/server/

   # Fallback: Set essential properties if server.properties is missing
   if [ ! -f /opt/minecraft/server/server.properties ]; then
     cat << 'EOF' > /opt/minecraft/server/server.properties
   enable-command-block=true
   spawn-protection=0
   view-distance=10
   difficulty=normal
   motd=Ephemeral Modded Minecraft Server
   EOF
   fi
   ```

3. **Persisting In-Game OP and Whitelist Changes:**
   Update `/opt/minecraft/server/backup.sh` to sync permission files back to S3 upon shutdown alongside the world archive:
   ```bash
   # Sync permissions and properties back to S3
   aws s3 cp /opt/minecraft/server/ops.json s3://$S3_BUCKET/$PROJECT_ID/config/ops.json || true
   aws s3 cp /opt/minecraft/server/whitelist.json s3://$S3_BUCKET/$PROJECT_ID/config/whitelist.json || true
   aws s3 cp /opt/minecraft/server/server.properties s3://$S3_BUCKET/$PROJECT_ID/config/server.properties || true
   ```
