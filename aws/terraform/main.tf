terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
provider "aws" { region = var.aws_region }

# --- 1. NETWORKING ---
resource "aws_vpc" "mc_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "mc_igw" { vpc_id = aws_vpc.mc_vpc.id }

resource "aws_subnet" "mc_subnet" {
  vpc_id = aws_vpc.mc_vpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "mc_rt" {
  vpc_id = aws_vpc.mc_vpc.id
  route { cidr_block = "0.0.0.0/0", gateway_id = aws_internet_gateway.mc_igw.id }
}

resource "aws_route_table_association" "mc_rta" {
  subnet_id = aws_subnet.mc_subnet.id
  route_table_id = aws_route_table.mc_rt.id
}

# --- 2. SECURITY GROUP ---
resource "aws_security_group" "mc_sg" {
  name = "minecraft-ephemeral-sg"
  vpc_id = aws_vpc.mc_vpc.id
  ingress { from_port = 25565, to_port = 25565, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 22, to_port = 22, protocol = "tcp", cidr_blocks = [var.admin_ip] }
  egress  { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

# --- 3. IAM (Allows EC2 to read/write to the S3 bucket) ---
resource "aws_iam_role" "mc_role" {
  name = "MinecraftEphemeralRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role = aws_iam_role.mc_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "s3_policy" {
  name = "MinecraftS3BackupPolicy"
  role = aws_iam_role.mc_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"], Effect = "Allow", Resource = ["arn:aws:s3:::${var.s3_bucket}", "arn:aws:s3:::${var.s3_bucket}/*"] }]
  })
}

resource "aws_iam_instance_profile" "mc_profile" {
  name = "MinecraftEphemeralProfile"
  role = aws_iam_role.mc_role.name
}

# --- 4. EC2 INSTANCE ---
data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners = ["099720109477"]
  filter { name = "name", values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"] }
}

resource "aws_instance" "mc_server" {
  ami = data.aws_ami.ubuntu_arm.id
  instance_type = "t4g.small"
  subnet_id = aws_subnet.mc_subnet.id
  vpc_security_group_ids = [aws_security_group.mc_sg.id]
  iam_instance_profile = aws_iam_instance_profile.mc_profile.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 15
  }

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y openjdk-21-jre-headless unzip wget curl jq awscli

    useradd -r -m -U -d /opt/minecraft -s /bin/bash minecraft
    mkdir -p /opt/minecraft/server

    # Install Ferium
    wget -q "https://github.com/gorilla-devs/ferium/releases/latest/download/ferium-linux-arm64-nogui.zip" -O /tmp/ferium.zip
    unzip -o /tmp/ferium.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/ferium

    # Restore world from S3 if it exists
    aws s3 cp s3://${var.s3_bucket}/${var.curseforge_project_id}/world.tar.gz /tmp/world.tar.gz || echo "No previous world found."
    if [ -f /tmp/world.tar.gz ]; then
      tar -xzf /tmp/world.tar.gz -C /opt/minecraft/server
    fi

    # Install Mods via Ferium
    sudo -u minecraft bash -c '
      cd /opt/minecraft/server
      echo -e "/opt/minecraft/server\ny\n" | ferium modpack add ${var.curseforge_project_id}
      ferium modpack upgrade
    '

    # Install baseline Fabric Server
    echo "eula=true" > /opt/minecraft/server/eula.txt
    cd /opt/minecraft/server
    wget -qO fabric-installer.jar https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.0.1/fabric-installer-1.0.1.jar
    sudo -u minecraft java -jar fabric-installer.jar server -mcversion 1.21.1 -downloadMinecraft
    
    # Create the Backup Script 
    cat << 'SCRIPT' > /opt/minecraft/server/backup.sh
    #!/bin/bash
    echo "Zipping world data..."
    tar -czf /tmp/world.tar.gz -C /opt/minecraft/server world
    echo "Uploading to S3..."
    aws s3 cp /tmp/world.tar.gz s3://${var.s3_bucket}/${var.curseforge_project_id}/world.tar.gz
    SCRIPT
    chmod +x /opt/minecraft/server/backup.sh
    chown -R minecraft:minecraft /opt/minecraft

    # Setup Systemd Service
    cat << 'SERVICE' > /etc/systemd/system/minecraft.service
    [Unit]
    Description=Minecraft Server
    After=network.target

    [Service]
    User=minecraft
    WorkingDirectory=/opt/minecraft/server
    ExecStart=/usr/bin/java -Xmx1500M -Xms512M -jar fabric-server-launch.jar nogui
    SuccessExitStatus=143
    TimeoutStopSec=60
    ExecStopPost=/opt/minecraft/server/backup.sh

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable minecraft
    systemctl start minecraft
  EOF
}

output "server_ip" {
  value = aws_instance.mc_server.public_ip
}