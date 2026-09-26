# Server Lifecycle Runbook

Use this guide every time you want to play or when you are done playing. The automation ensures the server always boots with your saved world and self-destructs the billing infrastructure when finished.

## 1. Starting the Server

Find the Modpack you want to play on CurseForge and copy its **Project ID** (located on the right sidebar under "About Project").

Run the up command from the root of the repository:

```bash
./manager.sh up <PROJECT_ID>
# Example for Fabulously Optimized:
./manager.sh up 396246
```

### What happens behind the scenes:

1. **Network Creation:** Terraform builds a fresh VPC, Subnet, Internet Gateway, and Security Group from scratch.
2. **Compute Launch:** An ARM64 `t4g.small` Ubuntu instance is deployed.
3. **Bootstrapping (3-5 minutes):** The instance runs `server_bootstrap.sh` in the background to:
   - Download Java and Ferium.
   - Pull your existing `world.tar.gz` from S3 (if you played this modpack before).
   - Download the modpack and parse the manifest to determine the exact Minecraft version.
   - Install the correct Modloader (Forge, NeoForge, or Fabric) dynamically.
   - Launch the server.

The terminal will output an IP address. Wait roughly 5 minutes, then connect to that IP address in Minecraft.

## 2. Server Management & Logs

Because this server has no open SSH port (for security), you manage it directly via AWS Systems Manager (SSM).

To view the live startup logs if the server isn't appearing online:

1. Go to the **EC2 Dashboard** in AWS.
2. Select your `Minecraft-Ephemeral-Server` instance and click **Connect**.
3. Choose the **Session Manager** tab and click Connect.
4. Read the bootstrap log:
   ```bash
   cat /var/log/server_bootstrap.log
   ```
5. Check the live Minecraft console:
   ```bash
   sudo su - minecraft
   tmux attach -t mc-server # (If using tmux) or view the systemd journal
   journalctl -u minecraft -f
   ```

## 3. Tearing Down (Zeroing Costs)

When you and your friends are done playing, you must destroy the infrastructure to stop incurring EC2 hourly charges.

```bash
./manager.sh down <PROJECT_ID>
```

### What happens behind the scenes:

1. **Graceful Shutdown:** Terraform issues a termination signal to the EC2 instance.
2. **Backup Hook:** Systemd catches the signal, stops the Java process safely, zips the `world` folder, and uploads it to your S3 bucket.
3. **Obliteration:** Terraform waits for the instance to disappear, then systematically deletes the Security Group, Subnet, Internet Gateway, Route Tables, and VPC.
4. **Verification:** Your AWS billable active resources return to 0. Your world is safe in S3.
